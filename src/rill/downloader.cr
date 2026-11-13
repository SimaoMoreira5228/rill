require "file"
require "path"
require "uri"

require "./cancellation"
require "./download_progress"
require "./errors"
require "./format"
require "./hls/parser"
require "./hls/playlist"
require "./http_client"
require "./request_options"

module Rill
  class Downloader
    PART_SUFFIX       = ".part"
    CONTENT_RANGE     = /\Abytes (\d+)-(\d+)\/(\d+|\*)\z/
    PROGRESS_INTERVAL = 100.milliseconds

    class ProgressWriter < IO
      property total : Int64?

      def initialize(
        @file : IO,
        @path : String,
        @downloaded : Int64,
        @cancellation : Cancellation?,
        @callback : Proc(DownloadProgress, Nil)?,
      )
        @last_emit = Time.instant
      end

      def base_offset=(value : Int64) : Nil
        @downloaded = value
      end

      def read(slice : Bytes) : Int32
        raise IO::Error.new("progress writer is not readable")
      end

      def write(slice : Bytes) : Nil
        @cancellation.try(&.check!)

        begin
          @file.write(slice)
        rescue ex : IO::Error
          raise DownloadWriteError.new(@path, ex)
        end

        @downloaded += slice.size
        emit(force: false)
      end

      def emit(force : Bool) : Nil
        callback = @callback
        return unless callback

        now = Time.instant
        return unless force || now - @last_emit >= PROGRESS_INTERVAL

        @last_emit = now
        callback.call(DownloadProgress.new(@downloaded, @total))
      end
    end

    @options : RequestOptions
    @http : HTTPClient

    def initialize(
      options : RequestOptions = RequestOptions.new,
      http : HTTPClient? = nil,
      @resume : Bool = true,
      @overwrite : Bool = false,
    )
      @options = options
      @http = http || HTTPClient.new(options)
    end

    def download(
      source : Format | String | URI,
      target : String | Path,
      cancellation : Cancellation? = nil,
      on_progress : Proc(DownloadProgress, Nil)? = nil,
    ) : Path
      url = case source
            when Format then source.url
            else             source
            end
      format = source.is_a?(Format) ? source : nil
      target_path = Path.new(target.to_s)
      part_path = Path.new("#{target_path}#{PART_SUFFIX}")

      if File.exists?(target_path) && !@overwrite
        raise FileExistsError.new(target_path.to_s)
      end

      if format.try(&.protocol.hls?)
        File.delete(part_path) if File.exists?(part_path)
        transfer_hls(url, part_path, cancellation, on_progress)
      else
        File.delete(part_path) if !@resume && File.exists?(part_path)
        transfer(url, part_path, cancellation, on_progress)
      end

      publish(part_path, target_path)
      target_path
    rescue ex : File::Error
      raise DownloadWriteError.new(target_path.to_s, ex)
    end

    private def transfer(
      url : Format | String | URI,
      part_path : Path,
      cancellation : Cancellation?,
      on_progress : Proc(DownloadProgress, Nil)?,
    ) : Nil
      attempt = 0

      loop do
        attempt += 1
        offset = current_offset(part_path)
        request_headers = build_request_headers(offset)
        expected_total = nil

        begin
          File.open(part_path, offset > 0 ? "r+b" : "w+b") do |file|
            file.seek(offset)
            writer = ProgressWriter.new(file, part_path.to_s, offset, cancellation, on_progress)
            writer.emit(force: true)

            @http.stream_to(url, writer, headers: request_headers, max_bytes: nil) do |status, headers, _|
              resumed_offset = response_offset(status, headers, offset, part_path, file)
              expected_total = expected_total_for(status, headers)
              writer.base_offset = resumed_offset
              writer.total = expected_total
            end

            writer.emit(force: true)
          end

          verify_size(part_path, expected_total)
          return
        rescue ex : NetworkError | IncompleteDownloadError
          raise ex if attempt > @options.retries
          sleep(retry_wait(attempt))
        rescue ex : ResumeError
          File.delete(part_path) if File.exists?(part_path)
          raise ex if attempt > @options.retries
        rescue ex : HTTPError
          if offset > 0 && ex.status.code == 416
            File.delete(part_path) if File.exists?(part_path)
            raise ex if attempt > @options.retries
            next
          end

          raise ex unless retryable_status?(ex.status)
          raise ex if attempt > @options.retries

          sleep(retry_wait(attempt))
        end
      end
    end

    private def retryable_status?(status : HTTP::Status) : Bool
      {
        408, 425, 429, 500, 502, 503, 504,
      }.includes?(status.code)
    end

    private def transfer_hls(
      url : String | URI,
      part_path : Path,
      cancellation : Cancellation?,
      on_progress : Proc(DownloadProgress, Nil)?,
    ) : Nil
      response = @http.get(url)
      playlist = Hls::Parser.parse(response.body, response.url)

      unless playlist.is_a?(Hls::MediaPlaylist)
        raise UnsupportedManifestError.new("nested HLS master playlists are not supported")
      end

      validate_hls(playlist)

      File.open(part_path, "w+b") do |file|
        writer = ProgressWriter.new(file, part_path.to_s, 0_i64, cancellation, on_progress)
        writer.emit(force: true)

        if map_url = playlist.map_url
          @http.stream_to(map_url, writer)
        end

        playlist.segments.each do |segment|
          @http.stream_to(segment.url, writer)
        end

        writer.emit(force: true)
      end
    rescue ex : Rill::Error | IO::Error
      File.delete(part_path) if File.exists?(part_path)
      raise ex
    end

    private def validate_hls(playlist : Hls::MediaPlaylist) : Nil
      if playlist.encrypted
        raise UnsupportedManifestError.new("encrypted HLS playlists are not supported")
      end

      unless playlist.ended
        raise UnsupportedManifestError.new("live HLS playlists are not supported")
      end

      if playlist.map_byte_range
        raise UnsupportedManifestError.new("HLS map byte ranges are not supported")
      end

      if playlist.segments.any? { |segment| segment.byte_range }
        raise UnsupportedManifestError.new("HLS segment byte ranges are not supported")
      end
    end

    private def current_offset(part_path : Path) : Int64
      return 0_i64 unless @resume
      return 0_i64 unless File.exists?(part_path)

      File.size(part_path)
    end

    private def build_request_headers(offset : Int64) : HTTP::Headers
      headers = HTTP::Headers.new
      headers["Accept-Encoding"] = "identity"

      if offset > 0
        headers["Range"] = "bytes=#{offset}-"
      end

      headers
    end

    private def response_offset(
      status : HTTP::Status,
      headers : HTTP::Headers,
      requested_offset : Int64,
      part_path : Path,
      file : File,
    ) : Int64
      return 0_i64 if requested_offset.zero?

      if status.code == 206
        range = parse_content_range(headers["Content-Range"]?)
        unless range && range[:start] == requested_offset
          raise ResumeError.new(part_path.to_s, "server returned an invalid Content-Range")
        end

        requested_offset
      else
        begin
          file.truncate(0)
          file.seek(0)
        rescue ex : IO::Error
          raise DownloadWriteError.new(part_path.to_s, ex)
        end

        0_i64
      end
    end

    private def expected_total_for(status : HTTP::Status, headers : HTTP::Headers) : Int64?
      if status.code == 206
        range = parse_content_range(headers["Content-Range"]?)
        return nil unless range
        return range[:total] if range[:total]
        return range[:end] + 1
      end

      headers["Content-Length"]?.try(&.to_i64?)
    end

    private def parse_content_range(
      value : String?,
    ) : NamedTuple(start: Int64, end: Int64, total: Int64?)?
      return nil unless value

      match = CONTENT_RANGE.match(value.strip)
      return nil unless match

      start = match[1].to_i64?
      finish = match[2].to_i64?
      return nil unless start && finish
      return nil if finish < start

      total = match[3] == "*" ? nil : match[3].to_i64?
      return nil if total && finish >= total

      {start: start, end: finish, total: total}
    end

    private def verify_size(part_path : Path, expected_total : Int64?) : Nil
      return unless expected_total

      actual = File.size(part_path)
      return if actual == expected_total

      raise IncompleteDownloadError.new(part_path.to_s, expected_total, actual)
    end

    private def publish(part_path : Path, target_path : Path) : Nil
      if !@overwrite && File.exists?(target_path)
        raise FileExistsError.new(target_path.to_s)
      end

      begin
        File.rename(part_path, target_path)
      rescue ex : File::Error
        unless File.exists?(target_path)
          raise DownloadWriteError.new(target_path.to_s, ex)
        end

        File.delete(target_path)
        File.rename(part_path, target_path)
      end
    end

    private def retry_wait(attempt : Int32) : Time::Span
      @options.retry_delay * (1 << (attempt - 1))
    end
  end
end
