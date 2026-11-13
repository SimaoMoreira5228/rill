require "uri"

require "../extractor"
require "../format"
require "../media"

module Rill::Extractors
  class DirectMedia < Extractor
    VIDEO_EXTENSIONS = %w(
      3gp avi flv m2ts mkv mov mp4 m4v mpg mpeg ogv ts webm wmv
    )

    AUDIO_EXTENSIONS = %w(
      aac aif aiff ape flac m4a mp3 oga ogg opus shn wav wma
    )

    def name : String
      "direct"
    end

    def matches?(url : URI) : Bool
      extension = extension_for(url)
      !extension.nil?
    end

    def extract(url : URI, client : HTTPClient) : Media
      extension = extension_for(url)
      unless extension
        raise UnsupportedUrlError.new(url.to_s)
      end

      format = Format.new(
        format_id: "direct",
        url: url,
        kind: kind_for(extension),
        container: extension,
      )

      Media.new(
        title: title_for(url),
        webpage_url: url,
        extractor: name,
        formats: [format],
      )
    end

    private def extension_for(url : URI) : String?
      return nil unless url.scheme == "http" || url.scheme == "https"

      extension = File.extname(url.path).lchop('.').downcase
      return nil if extension.empty?

      if VIDEO_EXTENSIONS.includes?(extension) || AUDIO_EXTENSIONS.includes?(extension)
        extension
      end
    end

    private def kind_for(extension : String) : FormatKind
      if AUDIO_EXTENSIONS.includes?(extension)
        FormatKind::Audio
      else
        FormatKind::Combined
      end
    end

    private def title_for(url : URI) : String
      basename = File.basename(url.path)
      stem = File.basename(basename, File.extname(basename))
      decoded = URI.decode(stem)
      decoded.empty? ? "media" : decoded
    end
  end
end
