require "../cancellation"
require "../download_progress"
require "../errors"
require "../hls/decrypting_writer"
require "../hls/decryption"
require "../hls/encryption"
require "../hls/parser"
require "../hls/playlist"
require "../http_client"
require "../segment_assembly"

module Rill
  class Downloader
    LIVE_STALL_POLLS = 12

    private def transfer_hls(
      url : String | URI,
      part_path : Path,
      target_path : Path,
      overwrite : Bool,
      cancellation : Cancellation?,
      on_progress : Proc(DownloadProgress, Nil)?,
      headers : HTTP::Headers? = nil,
    ) : Nil
      response = @http.get(url, headers)
      playlist = Hls::Parser.parse(response.body, response.url)

      unless playlist.is_a?(Hls::MediaPlaylist)
        raise UnsupportedManifestError.new("nested HLS master playlists are not supported")
      end

      if playlist.ended
        transfer_hls_vod(playlist, part_path, cancellation, on_progress, headers)
      else
        transfer_hls_live(
          playlist,
          response.url,
          part_path,
          target_path,
          overwrite,
          cancellation,
          on_progress,
          headers,
        )
      end
    end

    private def transfer_hls_vod(
      playlist : Hls::MediaPlaylist,
      part_path : Path,
      cancellation : Cancellation?,
      on_progress : Proc(DownloadProgress, Nil)?,
      headers : HTTP::Headers? = nil,
    ) : Nil
      validate_hls_vod(playlist)
      validate_hls_assembly(playlist)

      File.open(part_path, "w+b") do |file|
        writer = ProgressWriter.new(file, part_path.to_s, 0_i64, cancellation, on_progress)
        writer.emit(force: true)
        keys = {} of String => Bytes

        if map_url = playlist.map_url
          @http.stream_to(map_url, writer, headers)
        end

        playlist.segments.each_with_index do |segment, index|
          stream_hls_segment(segment, writer, playlist.media_sequence + index, keys, headers)
        end

        writer.emit(force: true)
      end
    rescue ex : Rill::Error | IO::Error
      remove_part(part_path)
      raise ex
    end

    private def transfer_hls_live(
      playlist : Hls::MediaPlaylist,
      playlist_url : URI,
      part_path : Path,
      target_path : Path,
      overwrite : Bool,
      cancellation : Cancellation?,
      on_progress : Proc(DownloadProgress, Nil)?,
      headers : HTTP::Headers? = nil,
    ) : Nil
      validate_hls_live(playlist)
      validate_hls_assembly(playlist)

      File.open(part_path, "w+b") do |file|
        writer = ProgressWriter.new(file, part_path.to_s, 0_i64, cancellation, on_progress)
        writer.emit(force: true)

        current = playlist
        next_sequence = live_start_sequence(current)
        stalled_polls = 0
        keys = {} of String => Bytes
        written_map : String? = nil

        loop do
          if current.media_sequence > next_sequence
            raise ManifestError.new(
              "live HLS skipped segments #{next_sequence}..#{current.media_sequence - 1}",
            )
          end

          written_map = write_live_map(current, writer, written_map, headers)
          previous = next_sequence
          next_sequence = download_live_segments(current, writer, next_sequence, keys, headers)
          if next_sequence == previous && !current.ended
            stalled_polls += 1
            if stalled_polls >= LIVE_STALL_POLLS
              raise ManifestError.new("live HLS playlist stopped advancing")
            end
          else
            stalled_polls = 0
          end

          break if current.ended

          sleep(live_interval(current))
          cancellation.try(&.check!)

          response = @http.get(playlist_url, headers)
          cancellation.try(&.check!)

          refreshed = Hls::Parser.parse(response.body, response.url)
          unless refreshed.is_a?(Hls::MediaPlaylist)
            raise UnsupportedManifestError.new("live HLS playlist changed to a master playlist")
          end

          validate_hls_live(refreshed)
          validate_hls_assembly(refreshed)
          current = refreshed
        end

        writer.emit(force: true)
      end
    rescue ex : CancelledError
      publish_live_part(part_path, target_path, overwrite)
      raise ex
    rescue ex : Rill::Error | IO::Error
      remove_part(part_path) if File.exists?(part_path) && File.size(part_path) == 0
      raise ex
    end

    private def write_live_map(
      playlist : Hls::MediaPlaylist,
      writer : ProgressWriter,
      written_map : String?,
      headers : HTTP::Headers?,
    ) : String?
      map_url = playlist.map_url
      return written_map unless map_url

      key = map_url.to_s
      return written_map if written_map == key

      @http.stream_to(map_url, writer, headers)
      key
    end

    private def download_live_segments(
      playlist : Hls::MediaPlaylist,
      writer : ProgressWriter,
      next_sequence : Int64,
      keys : Hash(String, Bytes),
      headers : HTTP::Headers?,
    ) : Int64
      playlist.segments.each_with_index do |segment, index|
        sequence = playlist.media_sequence + index
        next if sequence < next_sequence

        stream_hls_segment(segment, writer, sequence, keys, headers)
        writer.emit(force: true)
        next_sequence = sequence + 1
      end

      next_sequence
    end

    private def stream_hls_segment(
      segment : Hls::Segment,
      destination : IO,
      sequence : Int64,
      keys : Hash(String, Bytes),
      headers : HTTP::Headers?,
    ) : Nil
      key = segment.key
      unless key
        @http.stream_to(segment.url, destination, headers)
        return
      end

      cipher = Hls::Decryption.cipher(key, hls_key(key, keys, headers), sequence)
      writer = Hls::DecryptingWriter.new(destination, cipher)
      @http.stream_to(segment.url, writer, headers)
      writer.finish
    end

    private def hls_key(
      key : Hls::Key,
      keys : Hash(String, Bytes),
      headers : HTTP::Headers?,
    ) : Bytes
      url = key.url
      unless url
        raise UnsupportedManifestError.new("HLS AES-128 key has no URI")
      end

      cache_key = url.to_s
      if cached = keys[cache_key]?
        return cached
      end

      bytes = @http.get(url, headers).body.to_slice
      unless bytes.size == 16
        raise ManifestError.new("HLS AES-128 key is #{bytes.size} bytes, expected 16")
      end

      keys[cache_key] = bytes
    end

    private def live_start_sequence(playlist : Hls::MediaPlaylist) : Int64
      return playlist.media_sequence if playlist.ended
      return playlist.media_sequence if playlist.segments.empty?

      playlist.media_sequence + playlist.segments.size - 1
    end

    private def live_interval(playlist : Hls::MediaPlaylist) : Time::Span
      target = playlist.target_duration || playlist.segments.map(&.duration).max? || 2.0
      interval = target / 2.0
      interval = 1.0 if interval < 1.0
      interval.seconds
    end

    private def publish_live_part(part_path : Path, target_path : Path, overwrite : Bool) : Nil
      return unless File.exists?(part_path)

      if File.size(part_path) == 0
        remove_part(part_path)
        return
      end

      publish(part_path, target_path, overwrite)
    rescue Rill::Error
      # Keep the part file when the final name is already taken.
    end

    private def validate_hls_assembly(playlist : Hls::MediaPlaylist) : Nil
      extensions = playlist.segments.map do |segment|
        File.extname(segment.url.path).lchop('.').downcase
      end

      SegmentAssembly.for_hls(playlist.map_url, extensions)
    end

    private def validate_hls_vod(playlist : Hls::MediaPlaylist) : Nil
      Hls::Encryption.validate(playlist)

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

    private def validate_hls_live(playlist : Hls::MediaPlaylist) : Nil
      Hls::Encryption.validate(playlist)

      if playlist.map_byte_range
        raise UnsupportedManifestError.new("HLS map byte ranges are not supported")
      end

      if playlist.segments.any? { |segment| segment.byte_range }
        raise UnsupportedManifestError.new("HLS segment byte ranges are not supported")
      end
    end
  end
end
