require "json"
require "set"
require "uri"

require "../errors"
require "../extractor"
require "../format"
require "../http_url"
require "../json_value"
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
        id: JsonValue.string(payload["uuid"]?) || identifier,
        title: JsonValue.string(payload["name"]?) || identifier,
        description: JsonValue.string(payload["description"]?),
        webpage_url: url,
        uploader: uploader(payload),
        duration_seconds: JsonValue.number(payload["duration"]?),
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

    private def api_payload(client : HTTPClient, api_url : URI, url : URI) : Hash(String, JSON::Any)
      response = client.get(api_url)
      payload = JSON.parse(response.body).as_h?
      unless payload
        raise MediaUnavailableError.new(url.to_s, "video metadata is not a JSON object")
      end

      payload
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

    private def formats_from(payload : Hash(String, JSON::Any)) : Array(Format)
      duration = JsonValue.number(payload["duration"]?)
      language = language_for(payload)
      formats = [] of Format
      seen = Set(String).new

      files = payload["files"]?.try(&.as_a?) || [] of JSON::Any
      files.each_with_index do |file, index|
        file_hash = file.as_h?
        next unless file_hash

        file_url = HttpUrl.absolute(JsonValue.string(file_hash["fileUrl"]?))
        next unless file_url

        resolution = file_hash["resolution"]?.try(&.as_h?)
        height = resolution.try(&.["id"]?).try(&.as_i64?)
        height = nil if height && (height <= 0 || height > 100_000)
        label = resolution.try(&.["label"]?).try(&.as_s?)
        audio_only = height.nil?

        format_id = audio_only ? "audio" : "#{height}p"
        if seen.includes?(format_id)
          format_id = "#{format_id}-#{index + 1}"
        end
        seen << format_id

        size = integer(file_hash["size"]?)
        formats << Format.new(
          format_id: format_id,
          url: file_url,
          kind: audio_only ? FormatKind::Audio : FormatKind::Combined,
          container: container_for(file_url),
          bitrate: bitrate(size, duration),
          height: audio_only ? nil : height.try(&.to_i32),
          fps: JsonValue.positive_number(file_hash["fps"]?),
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
      payload : Hash(String, JSON::Any),
      formats : Array(Format),
      language : String?,
    ) : Nil
      playlists = payload["streamingPlaylists"]?.try(&.as_a?) || [] of JSON::Any

      playlists.each_with_index do |playlist, index|
        playlist_hash = playlist.as_h?
        next unless playlist_hash

        playlist_url = HttpUrl.absolute(JsonValue.string(playlist_hash["playlistUrl"]?))
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

    private def uploader(payload : Hash(String, JSON::Any)) : String?
      account = payload["account"]?.try(&.as_h?)
      return nil unless account

      JsonValue.string(account["displayName"]?) || JsonValue.string(account["name"]?)
    end

    private def thumbnail_url(url : URI, payload : Hash(String, JSON::Any)) : URI?
      path = JsonValue.string(payload["thumbnailPath"]?) || JsonValue.string(payload["previewPath"]?)
      return nil unless path
      return nil unless path.starts_with?('/')

      port = url.port
      host = port ? "#{url.host}:#{port}" : url.host.to_s
      HttpUrl.absolute("#{url.scheme}://#{host}#{path}")
    end

    private def language_for(payload : Hash(String, JSON::Any)) : String?
      value = payload["language"]?
      return nil unless value

      if hash = value.as_h?
        JsonValue.string(hash["id"]?)
      else
        value.as_s?
      end
    end

    private def date_value(payload : Hash(String, JSON::Any)) : String?
      value = JsonValue.string(payload["publishedAt"]?)
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

    private def integer(value : JSON::Any?) : Int64?
      parsed = JsonValue.integer(value)
      return nil unless parsed && parsed >= 0

      parsed
    end
  end
end
