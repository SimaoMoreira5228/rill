require "json"
require "set"
require "uri"

require "../errors"
require "../extractor"
require "../format"
require "../media"

module Rill::Extractors
  class PeerTube < Extractor
    VIDEO_PATH = %r{\A/(?:w|videos/(?:watch|embed))/([A-Za-z0-9-]+)/?\z}

    def initialize(@api_base : String? = nil)
    end

    def name : String
      "peertube"
    end

    def matches?(url : URI) : Bool
      return false unless url.scheme == "http" || url.scheme == "https"

      !VIDEO_PATH.match(url.path).nil?
    end

    def extract(url : URI, client : HTTPClient) : Media
      identifier = identifier_for(url)
      unless identifier
        raise UnsupportedUrlError.new(url.to_s)
      end

      api_url = URI.parse("#{api_base(url)}/api/v1/videos/#{URI.encode_path_segment(identifier)}")
      payload = api_payload(client, api_url, url)

      if payload["isLive"]?.try(&.as_bool?)
        raise MediaUnavailableError.new(url.to_s, "live videos are not supported")
      end

      formats = formats_from(payload)
      if formats.empty?
        raise MediaUnavailableError.new(url.to_s, "video has no downloadable files")
      end

      Media.new(
        id: scalar_string(payload["uuid"]?) || identifier,
        title: scalar_string(payload["name"]?) || identifier,
        description: scalar_string(payload["description"]?),
        webpage_url: url,
        uploader: uploader(payload),
        duration_seconds: number(payload["duration"]?),
        thumbnail_url: thumbnail_url(url, payload),
        upload_date: date_value(payload),
        extractor: name,
        formats: formats,
      )
    end

    private def identifier_for(url : URI) : String?
      match = VIDEO_PATH.match(url.path)
      return nil unless match

      identifier = URI.decode(match[1])
      identifier.empty? ? nil : identifier
    end

    private def api_base(url : URI) : String
      @api_base || begin
        port = url.port
        if port
          "#{url.scheme}://#{url.host}:#{port}"
        else
          "#{url.scheme}://#{url.host}"
        end
      end
    end

    private def api_payload(client : HTTPClient, api_url : URI, url : URI) : JSON::Any
      response = client.get(api_url)
      JSON.parse(response.body)
    rescue ex : HTTPError
      case ex.status.code
      when 401, 403, 404
        raise MediaUnavailableError.new(url.to_s, "video is unavailable, private, or protected")
      else
        raise ex
      end
    rescue JSON::ParseException
      raise MediaUnavailableError.new(url.to_s, "video metadata is not valid JSON")
    end

    private def formats_from(payload : JSON::Any) : Array(Format)
      duration = number(payload["duration"]?)
      language = language_for(payload)
      formats = [] of Format
      seen = Set(String).new

      files = payload["files"]?.try(&.as_a?) || [] of JSON::Any
      files.each_with_index do |file, index|
        file_url = parse_uri(scalar_string(file["fileUrl"]?))
        next unless file_url

        resolution = file["resolution"]?
        height = resolution.try(&.["id"]?).try(&.as_i?)
        label = resolution.try(&.["label"]?).try(&.as_s?)
        audio_only = height.nil? || height == 0

        format_id = audio_only ? "audio" : "#{height}p"
        if seen.includes?(format_id)
          format_id = "#{format_id}-#{index + 1}"
        end
        seen << format_id

        size = number(file["size"]?).try(&.to_i64)
        formats << Format.new(
          format_id: format_id,
          url: file_url,
          kind: audio_only ? FormatKind::Audio : FormatKind::Combined,
          container: container_for(file_url),
          bitrate: bitrate(size, duration),
          height: audio_only ? nil : height,
          fps: positive_float(file["fps"]?),
          filesize: size,
          language: language,
          note: label,
        )
      end

      if formats.empty?
        append_hls_formats(payload, formats, language)
      end

      formats
    end

    private def append_hls_formats(
      payload : JSON::Any,
      formats : Array(Format),
      language : String?,
    ) : Nil
      playlists = payload["streamingPlaylists"]?.try(&.as_a?) || [] of JSON::Any

      playlists.each_with_index do |playlist, index|
        playlist_url = parse_uri(scalar_string(playlist["playlistUrl"]?))
        next unless playlist_url

        formats << Format.new(
          format_id: playlists.size == 1 ? "hls" : "hls-#{index + 1}",
          url: playlist_url,
          kind: FormatKind::Combined,
          protocol: FormatProtocol::Hls,
          language: language,
          note: "HLS",
        )
      end
    end

    private def uploader(payload : JSON::Any) : String?
      account = payload["account"]?
      return nil unless account

      scalar_string(account["displayName"]?) || scalar_string(account["name"]?)
    end

    private def thumbnail_url(url : URI, payload : JSON::Any) : URI?
      path = scalar_string(payload["thumbnailPath"]?) || scalar_string(payload["previewPath"]?)
      return nil unless path
      return nil unless path.starts_with?('/')

      port = url.port
      host = port ? "#{url.host}:#{port}" : url.host.to_s
      parse_uri("#{url.scheme}://#{host}#{path}")
    end

    private def language_for(payload : JSON::Any) : String?
      value = payload["language"]?
      return nil unless value

      if hash = value.as_h?
        scalar_string(hash["id"]?)
      else
        value.as_s?
      end
    end

    private def date_value(payload : JSON::Any) : String?
      value = scalar_string(payload["publishedAt"]?)
      return nil unless value
      return nil if value.size < 10

      value[0, 10]
    end

    private def container_for(url : URI) : String?
      extension = File.extname(url.path).lchop('.').downcase
      extension.empty? ? nil : extension
    end

    private def bitrate(size : Int64?, duration : Float64?) : Int64?
      return nil unless size && duration && duration > 0

      (size * 8 / duration).to_i64
    end

    private def number(value : JSON::Any?) : Float64?
      return nil unless value

      if integer = value.as_i64?
        integer.to_f
      elsif float = value.as_f?
        float
      else
        nil
      end
    end

    private def positive_float(value : JSON::Any?) : Float64?
      number = number(value)
      number && number > 0 ? number : nil
    end

    private def scalar_string(value : JSON::Any?) : String?
      return nil unless value

      if string = value.as_s?
        string
      elsif integer = value.as_i64?
        integer.to_s
      else
        nil
      end
    end

    private def parse_uri(value : String?) : URI?
      return nil unless value

      uri = URI.parse(value)
      return nil unless uri.scheme == "http" || uri.scheme == "https"
      return nil if uri.host.nil?

      uri
    rescue URI::Error
      nil
    end
  end
end
