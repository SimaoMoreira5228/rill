require "file"
require "json"
require "path"
require "uri"

require "./cancellation"
require "./dash/parser"
require "./download_plan"
require "./download_progress"
require "./errors"
require "./format"
require "./hls/parser"
require "./hls/playlist"
require "./http_client"
require "./media_muxer"
require "./segment_assembly"
require "./request_options"

module Rill
  class Downloader
    PART_SUFFIX       = ".part"
    META_SUFFIX       = ".meta"
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
    @media_muxer : MediaMuxer

    def initialize(
      options : RequestOptions = RequestOptions.new,
      http : HTTPClient? = nil,
      @resume : Bool = true,
      @overwrite : Bool = false,
      @media_muxer : MediaMuxer = MediaMuxer.new,
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
      download_source(
        source,
        target,
        cancellation,
        on_progress,
        check_target: true,
        overwrite: @overwrite,
      )
    end

    def download(
      plan : DownloadPlan,
      target : String | Path,
      cancellation : Cancellation? = nil,
      on_progress : Proc(DownloadProgress, Nil)? = nil,
    ) : Path
      download_plan(plan, target, cancellation, on_progress)
    end

    private def download_source(
      source : Format | String | URI,
      target : String | Path,
      cancellation : Cancellation?,
      on_progress : Proc(DownloadProgress, Nil)?,
      check_target : Bool,
      overwrite : Bool,
    ) : Path
      url = case source
            when Format then source.url
            else             source
            end
      format = source.is_a?(Format) ? source : nil
      target_path = Path.new(target.to_s)
      part_path = Path.new("#{target_path}#{PART_SUFFIX}")
      ensure_not_symlink(part_path)
      ensure_not_symlink(meta_path(part_path))

      if check_target && File.exists?(target_path) && !overwrite
        raise FileExistsError.new(target_path.to_s)
      end

      if format.try(&.protocol.hls?)
        remove_part(part_path)
        transfer_hls(url, part_path, cancellation, on_progress)
      elsif format.try(&.protocol.dash?)
        remove_part(part_path)
        transfer_dash(url, part_path, format.not_nil!.format_id, cancellation, on_progress)
      else
        remove_part(part_path) unless @resume
        chunk_size = format.try(&.range_chunk_size)
        total = format.try(&.filesize)

        if chunk_size && total && total > 0
          transfer_chunked(url, part_path, total, chunk_size, cancellation, on_progress)
        else
          transfer(url, part_path, cancellation, on_progress)
        end
      end

      publish(part_path, target_path, overwrite)
      target_path
    rescue ex : File::Error
      raise DownloadWriteError.new(target_path.to_s, ex)
    end

    private def download_plan(
      plan : DownloadPlan,
      target : String | Path,
      cancellation : Cancellation?,
      on_progress : Proc(DownloadProgress, Nil)?,
    ) : Path
      audio = plan.audio
      unless audio
        return download_source(
          plan.stream,
          target,
          cancellation,
          on_progress,
          check_target: true,
          overwrite: @overwrite,
        )
      end

      target_path = Path.new(target.to_s)
      if File.exists?(target_path) && !@overwrite
        raise FileExistsError.new(target_path.to_s)
      end

      video_path = Path.new("#{target_path}.video")
      audio_path = Path.new("#{target_path}.audio")
      completed = false

      begin
        download_part(plan.stream, video_path, cancellation, on_progress)
        download_part(audio, audio_path, cancellation, on_progress)
        @media_muxer.merge(video_path, audio_path, target_path, overwrite: @overwrite)
        completed = true
      ensure
        if completed
          File.delete(video_path) if File.exists?(video_path)
          File.delete(audio_path) if File.exists?(audio_path)
        end
      end

      target_path
    end

    private def download_part(
      format : Format,
      path : Path,
      cancellation : Cancellation?,
      on_progress : Proc(DownloadProgress, Nil)?,
    ) : Nil
      if format.filesize && File.exists?(path) && File.size(path) == format.filesize
        return
      end

      download_source(
        format,
        path,
        cancellation,
        on_progress,
        check_target: false,
        overwrite: true,
      )
    end

    private def transfer_chunked(
      url : Format | String | URI,
      part_path : Path,
      total : Int64,
      chunk_size : Int64,
      cancellation : Cancellation?,
      on_progress : Proc(DownloadProgress, Nil)?,
    ) : Nil
      validate_meta_url(part_path, url)
      failures = 0

      loop do
        offset = File.exists?(part_path) ? File.size(part_path) : 0_i64

        if offset > total
          remove_part(part_path)
          offset = 0_i64
        end

        break if offset == total

        chunk_end = Math.min(offset + chunk_size - 1, total - 1)
        expected = chunk_end - offset + 1
        headers = HTTP::Headers.new
        headers["Accept-Encoding"] = "identity"
        headers["Range"] = "bytes=#{offset}-#{chunk_end}"

        begin
          File.open(part_path, offset > 0 ? "r+b" : "w+b") do |file|
            file.seek(offset)
            writer = ProgressWriter.new(file, part_path.to_s, offset, cancellation, on_progress)
            writer.total = total
            writer.emit(force: true)

            @http.stream_to(url, writer, headers: headers) do |status, response_headers, _|
              range = parse_content_range(response_headers["Content-Range"]?)
              unless status.code == 206 &&
                     range && range[:start] == offset && range[:end] == chunk_end
                raise ResumeError.new(part_path.to_s, "server did not honor the range request")
              end

              if range_total = range[:total]
                unless range_total == total
                  raise ResumeError.new(part_path.to_s, "server reported a different total size")
                end
              end

              write_meta(part_path, url.to_s, response_headers, total)
            end

            writer.emit(force: true)
          end

          actual = File.size(part_path)
          unless actual == offset + expected
            raise IncompleteDownloadError.new(part_path.to_s, offset + expected, actual)
          end

          failures = 0
        rescue ex : NetworkError | IncompleteResponseError | IncompleteDownloadError
          failures += 1
          raise ex if failures > @options.retries
          sleep(@options.retry_wait(failures))
        rescue ex : HTTPError
          if ex.status.code == 416 && offset > 0
            remove_part(part_path)
            next
          end

          raise ex unless retryable_status?(ex.status)

          failures += 1
          raise ex if failures > @options.retries
          sleep(@options.retry_wait(failures))
        end
      end

      actual = File.exists?(part_path) ? File.size(part_path) : 0_i64
      return if actual == total

      raise IncompleteDownloadError.new(part_path.to_s, total, actual)
    end

    private def transfer(
      url : Format | String | URI,
      part_path : Path,
      cancellation : Cancellation?,
      on_progress : Proc(DownloadProgress, Nil)?,
    ) : Nil
      attempt = 0
      validate_meta_url(part_path, url)

      loop do
        attempt += 1
        offset = current_offset(part_path)
        meta = read_meta(part_path)
        request_headers = build_request_headers(offset, meta)
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
              write_meta(part_path, url.to_s, headers, expected_total)
            end

            writer.emit(force: true)
          end

          verify_size(part_path, expected_total)
          return
        rescue ex : NetworkError | IncompleteResponseError | IncompleteDownloadError
          raise ex if attempt > @options.retries
          sleep(@options.retry_wait(attempt))
        rescue ex : ResumeError
          remove_part(part_path)
          raise ex if attempt > @options.retries
        rescue ex : HTTPError
          if offset > 0 && ex.status.code == 416
            remove_part(part_path)
            raise ex if attempt > @options.retries
            next
          end

          raise ex unless retryable_status?(ex.status)
          raise ex if attempt > @options.retries

          sleep(@options.retry_wait(attempt))
        end
      end
    end

    private def retryable_status?(status : HTTP::Status) : Bool
      {
        408, 425, 429, 500, 502, 503, 504,
      }.includes?(status.code)
    end

    private def transfer_dash(
      url : String | URI,
      part_path : Path,
      reference : String,
      cancellation : Cancellation?,
      on_progress : Proc(DownloadProgress, Nil)?,
    ) : Nil
      response = @http.get(url)
      manifest = Dash::Parser.parse(response.body, response.url)
      representation = manifest.representations.find { |item| item.reference == reference }

      unless representation
        raise UnsupportedManifestError.new("DASH representation #{reference} is no longer present")
      end

      unless representation.supported?
        raise UnsupportedManifestError.new("DASH representation #{reference} uses unsupported segment information")
      end

      init_url, segments = representation.expand
      if segments.empty?
        raise ManifestError.new("DASH representation #{reference} has no segments")
      end

      mime = representation.mime
      unless mime
        raise UnsupportedManifestError.new("DASH representation #{reference} has no media type")
      end

      SegmentAssembly.for_dash(mime, !init_url.nil?)

      File.open(part_path, "w+b") do |file|
        writer = ProgressWriter.new(file, part_path.to_s, 0_i64, cancellation, on_progress)
        writer.emit(force: true)

        if init_url
          @http.stream_to(init_url, writer)
        end

        segments.each do |segment|
          @http.stream_to(segment.url, writer)
        end

        writer.emit(force: true)
      end
    rescue ex : Rill::Error | IO::Error
      remove_part(part_path)
      raise ex
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
      validate_hls_assembly(playlist)

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
      remove_part(part_path)
      raise ex
    end

    private def validate_hls_assembly(playlist : Hls::MediaPlaylist) : Nil
      extensions = playlist.segments.map do |segment|
        File.extname(segment.url.path).lchop('.').downcase
      end

      SegmentAssembly.for_hls(playlist.map_url, extensions)
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

    private def build_request_headers(offset : Int64, meta : Hash(String, String)) : HTTP::Headers
      headers = HTTP::Headers.new
      headers["Accept-Encoding"] = "identity"

      if offset > 0
        headers["Range"] = "bytes=#{offset}-"
        validator = meta["etag"]? || meta["last_modified"]?
        headers["If-Range"] = validator if validator
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

    private def publish(part_path : Path, target_path : Path, overwrite : Bool) : Nil
      if !overwrite && File.exists?(target_path)
        raise FileExistsError.new(target_path.to_s)
      end

      begin
        File.rename(part_path, target_path)
      rescue ex : File::Error
        unless overwrite && File.exists?(target_path)
          raise FileExistsError.new(target_path.to_s)
        end

        File.delete(target_path)
        File.rename(part_path, target_path)
      end

      remove_meta(part_path)
    end

    private def meta_path(part_path : Path) : Path
      Path.new("#{part_path}#{META_SUFFIX}")
    end

    private def read_meta(part_path : Path) : Hash(String, String)
      path = meta_path(part_path)
      return {} of String => String unless File.exists?(path)

      object = JSON.parse(File.read(path)).as_h?
      return {} of String => String unless object

      result = {} of String => String
      object.each do |key, value|
        text = value.as_s?
        result[key] = text if text
      end
      result
    rescue File::Error | JSON::ParseException
      {} of String => String
    end

    private def write_meta(
      part_path : Path,
      url : String,
      headers : HTTP::Headers,
      total : Int64?,
    ) : Nil
      values = read_meta(part_path)
      values["url"] = url
      if etag = headers["ETag"]?
        values["etag"] = etag
      end
      if modified = headers["Last-Modified"]?
        values["last_modified"] = modified
      end
      if total
        values["total"] = total.to_s
      end

      return unless values.size > 1

      JSON.build do |json|
        json.object do
          values.each do |key, value|
            json.field key, value
          end
        end
      end.tap do |content|
        File.write(meta_path(part_path), content)
      end
    rescue File::Error
      nil
    end

    private def validate_meta_url(part_path : Path, url : String | URI) : Nil
      return unless @resume
      return unless File.exists?(part_path)

      meta = read_meta(part_path)
      stored = meta["url"]?
      return unless stored
      return if stored == url.to_s

      remove_part(part_path)
    end

    private def remove_part(part_path : Path) : Nil
      File.delete(part_path) if File.exists?(part_path)
      remove_meta(part_path)
    end

    private def remove_meta(part_path : Path) : Nil
      path = meta_path(part_path)
      File.delete(path) if File.exists?(path)
    end

    private def ensure_not_symlink(path : Path) : Nil
      return unless File.symlink?(path)

      raise DownloadError.new("refusing to use symlink #{path}")
    end
  end
end
