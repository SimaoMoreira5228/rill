require "uri"

require "../dash/parser"
require "../errors"
require "../extractor"
require "../format"
require "../media"

module Rill::Extractors
  class Dash < Extractor
    def name : String
      "dash"
    end

    def matches?(url : URI) : Bool
      return false unless url.scheme == "http" || url.scheme == "https"

      url.path.downcase.ends_with?(".mpd")
    end

    def extract(url : URI, client : HTTPClient) : Media
      response = client.get(url)
      manifest = Rill::Dash::Parser.parse(response.body, response.url)

      formats = [] of Format
      unsupported = false

      manifest.representations.each do |representation|
        unless representation.supported?(manifest.dynamic?)
          unsupported = true
          next
        end

        mime = representation.mime
        next unless mime

        audio = mime.audio?
        formats << Format.new(
          format_id: representation.reference,
          url: response.url,
          kind: audio ? FormatKind::Audio : FormatKind::Video,
          protocol: FormatProtocol::Dash,
          container: mime.container,
          bitrate: representation.bandwidth,
          video_codec: audio ? nil : (representation.codecs || mime.codecs),
          audio_codec: audio ? (representation.codecs || mime.audio_codec) : nil,
          width: representation.width,
          height: representation.height,
          fps: representation.fps,
          duration_seconds: representation.duration_seconds,
          language: representation.language,
          note: representation.codecs || "DASH",
          live: manifest.dynamic?,
        )
      end

      if formats.empty?
        reason = unsupported ? "DASH representations use unsupported segment information" : "DASH manifest has no representations"
        raise MediaUnavailableError.new(url.to_s, reason)
      end

      Media.new(
        title: title_for(url),
        webpage_url: url,
        duration_seconds: manifest.duration_seconds,
        extractor: name,
        formats: formats,
        is_live: manifest.dynamic?,
      )
    end

    private def title_for(url : URI) : String
      basename = File.basename(url.path)
      stem = File.basename(basename, File.extname(basename))
      decoded = URI.decode(stem)
      decoded.empty? ? "manifest" : decoded
    end
  end
end
