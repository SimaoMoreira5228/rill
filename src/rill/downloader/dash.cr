require "../cancellation"
require "../dash/parser"
require "../download_progress"
require "../errors"
require "../format"
require "../http_client"
require "../segment_assembly"

module Rill
  class Downloader
    private def transfer_dash(
      url : String | URI,
      part_path : Path,
      target_path : Path,
      overwrite : Bool,
      reference : String,
      cancellation : Cancellation?,
      on_progress : Proc(DownloadProgress, Nil)?,
      headers : HTTP::Headers? = nil,
    ) : Nil
      dynamic = false
      response = @http.get(url, headers)
      manifest = Dash::Parser.parse(response.body, response.url)
      dynamic = manifest.dynamic?

      if dynamic
        transfer_dash_live(
          url,
          part_path,
          target_path,
          overwrite,
          reference,
          manifest,
          cancellation,
          on_progress,
          headers,
        )
        return
      end

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
          @http.stream_to(init_url, writer, headers)
        end

        segments.each do |segment|
          @http.stream_to(segment.url, writer, headers)
        end

        writer.emit(force: true)
      end
    rescue ex : Rill::Error | IO::Error
      remove_part(part_path) unless dynamic
      raise ex
    end

    private def transfer_dash_live(
      url : String | URI,
      part_path : Path,
      target_path : Path,
      overwrite : Bool,
      reference : String,
      manifest : Dash::Manifest,
      cancellation : Cancellation?,
      on_progress : Proc(DownloadProgress, Nil)?,
      headers : HTTP::Headers?,
    ) : Nil
      representation = dash_representation(manifest, reference)
      mime = representation.mime
      unless mime
        raise UnsupportedManifestError.new("DASH representation #{reference} has no media type")
      end

      wrote = false
      init_written = false
      writer : ProgressWriter? = nil

      File.open(part_path, "w+b") do |file|
        writer = ProgressWriter.new(file, part_path.to_s, 0_i64, cancellation, on_progress)
        writer.emit(force: true)
        last_key : Int64? = nil
        last_step = 1_i64
        stalled = 0
        current = manifest

        loop do
          representation = dash_representation(current, reference)
          init_url, segments = if current.dynamic?
                                 representation.expand_live(
                                   Time.utc,
                                   current.availability_start_time,
                                   current.time_shift_buffer_depth,
                                 )
                               else
                                 representation.expand
                               end

          unless init_written
            SegmentAssembly.for_dash(mime, !init_url.nil?)
            if init_url
              @http.stream_to(init_url, writer, headers)
              writer.flush
              writer.commit
              wrote = true
            end
            init_written = true
          end

          if segments.empty?
            stalled += 1 if last_key
          else
            first_key = segments.first.key
            if last_key && first_key && first_key > last_key + last_step
              expected = last_key + last_step
              raise ManifestError.new("live DASH skipped segments #{expected}..#{first_key - 1}")
            end

            downloaded = false
            start_index = last_key.nil? ? segments.size - 1 : 0
            segments[start_index..].each do |segment|
              key = segment.key
              next unless key
              next if last_key && key <= last_key

              @http.stream_to(segment.url, writer, headers)
              writer.flush
              writer.commit
              writer.emit(force: true)
              last_key = key
              last_step = segment.key_step
              wrote = true
              downloaded = true
            end

            stalled = downloaded ? 0 : stalled + 1
          end

          break unless current.dynamic?

          if stalled >= LIVE_STALL_POLLS
            raise ManifestError.new("live DASH manifest stopped advancing")
          end

          sleep(live_dash_interval(current))
          cancellation.try(&.check!)

          response = @http.get(url, headers)
          cancellation.try(&.check!)
          current = Dash::Parser.parse(response.body, response.url)
        end

        writer.emit(force: true)
      end
    rescue ex : CancelledError
      truncate_part(part_path, writer.try(&.committed) || 0_i64)
      publish_live_part(part_path, target_path, overwrite)
      raise ex
    rescue ex : Rill::Error | IO::Error
      remove_part(part_path) if !wrote && File.exists?(part_path)
      raise ex
    end

    private def dash_representation(
      manifest : Dash::Manifest,
      reference : String,
    ) : Dash::Representation
      representation = manifest.representations.find { |item| item.reference == reference }
      unless representation
        raise UnsupportedManifestError.new("DASH representation #{reference} is no longer present")
      end

      unless representation.supported?(manifest.dynamic?)
        raise UnsupportedManifestError.new(
          "DASH representation #{reference} uses unsupported segment information",
        )
      end

      representation
    end

    private def live_dash_interval(manifest : Dash::Manifest) : Time::Span
      interval = manifest.minimum_update_period || 2.0
      if window = manifest.time_shift_buffer_depth
        interval = Math.min(interval, window / 2.0)
      end
      interval = 1.0 if interval < 1.0
      interval.seconds
    end
  end
end
