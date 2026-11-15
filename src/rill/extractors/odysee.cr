require "json"
require "uri"

require "../errors"
require "../extractor"
require "../format"
require "../http_url"
require "../json_value"
require "../media"
require "../mime_type"
require "./hls"

module Rill::Extractors
  class Odysee < Extractor
    DEFAULT_API = "https://api.lbry.tv/api/v1/proxy"
    REFERER     = "https://odysee.com/"
    HOSTS       = {"odysee.com", "www.odysee.com", "lbry.tv", "www.lbry.tv"}

    private record StreamFormats, formats : Array(Format), live : Bool

    def initialize(@api : String = DEFAULT_API)
    end

    def name : String
      "odysee"
    end

    def matches?(url : URI) : Bool
      return false unless url.scheme == "http" || url.scheme == "https"

      !claim_for(url).nil?
    end

    def extract(url : URI, client : HTTPClient) : Media
      claim = claim_for(url)
      unless claim
        raise UnsupportedUrlError.new(url.to_s)
      end

      uri = "lbry://#{claim}"
      item = resolve(client, uri, url)
      stream = item["reposted_claim"]?.try(&.as_h?) || item
      value = stream["value"]?.try(&.as_h?)
      stream_type = JsonValue.string(value.try(&.["stream_type"]?))

      unless value && (stream_type == "video" || stream_type == "audio")
        raise UnsupportedUrlError.new(url.to_s)
      end

      stream_type = stream_type.not_nil!
      claim_id = JsonValue.string(stream["claim_id"]?) || claim
      stream_uri = JsonValue.string(stream["canonical_url"]?) || uri
      streaming = streaming_url(client, stream_uri, claim_id, url)
      formats = formats_for(streaming, value, stream_type, client, url)

      Media.new(
        id: claim_id,
        title: JsonValue.string(value["title"]?) || claim,
        description: JsonValue.string(value["description"]?),
        webpage_url: url,
        uploader: uploader_for(stream),
        duration_seconds: duration_for(value, stream_type),
        thumbnail_url: thumbnail_for(value),
        upload_date: upload_date_for(stream),
        extractor: name,
        formats: formats.formats,
        is_live: formats.live,
      )
    end

    private def claim_for(url : URI) : String?
      host = url.host.try(&.downcase)
      return nil unless host && HOSTS.includes?(host)

      path = url.path
      path = path.lchop("/$/download/")
      path = path.lchop("/$/embed/")
      path = path.lchop('/')
      return nil if path.empty?

      decoded = URI.decode(path)
      segments = decoded.split('/').reject(&.empty?)
      return nil if segments.empty?

      last = segments.last
      return nil if last.starts_with?('@')
      return nil unless last.includes?(':') || last.includes?('#')

      decoded
    rescue ArgumentError
      nil
    end

    private def resolve(
      client : HTTPClient,
      uri : String,
      url : URI,
    ) : Hash(String, JSON::Any)
      response = rpc(client, "resolve") do |json|
        json.field "urls" do
          json.array do
            json.string(uri)
          end
        end
      end

      result = response["result"]?.try(&.as_h?)
      item = result.try(&.[uri]?).try(&.as_h?)
      unless item
        raise MediaUnavailableError.new(url.to_s, "claim could not be resolved")
      end

      if error = item["error"]?.try(&.as_h?)
        message = JsonValue.string(error["text"]?) ||
                  JsonValue.string(error["name"]?) ||
                  "claim could not be resolved"
        raise MediaUnavailableError.new(url.to_s, message)
      end

      item
    end

    private def streaming_url(
      client : HTTPClient,
      uri : String,
      claim_id : String,
      url : URI,
    ) : URI
      response = rpc(client, "get") do |json|
        json.field "uri", uri
        json.field "claim_id", claim_id
      end

      result = response["result"]?.try(&.as_h?)
      streaming = HttpUrl.absolute(JsonValue.string(result.try(&.["streaming_url"]?)))
      unless streaming
        raise MediaUnavailableError.new(url.to_s, "claim has no streaming URL")
      end

      streaming
    end

    private def rpc(
      client : HTTPClient,
      method : String,
      & : JSON::Builder ->
    ) : Hash(String, JSON::Any)
      body = JSON.build do |json|
        json.object do
          json.field "method", method
          json.field "params" do
            json.object do
              yield json
            end
          end
        end
      end

      headers = HTTP::Headers.new
      headers["Content-Type"] = "application/json-rpc"

      response = client.post(@api, body, headers)
      payload = JSON.parse(response.body).as_h?
      unless payload
        raise MediaUnavailableError.new(@api, "Odysee response is not a JSON object")
      end

      if error = payload["error"]?.try(&.as_h?)
        message = JsonValue.string(error["message"]?) || "unknown error"
        raise MediaUnavailableError.new(@api, "Odysee API error: #{message}")
      end

      payload
    rescue JSON::ParseException
      raise MediaUnavailableError.new(@api, "Odysee response is not valid JSON")
    end

    private def formats_for(
      streaming : URI,
      value : Hash(String, JSON::Any),
      stream_type : String,
      client : HTTPClient,
      url : URI,
    ) : StreamFormats
      headers = HTTP::Headers.new
      headers["Referer"] = REFERER

      response = begin
        client.head(streaming, headers)
      rescue ex : HTTPError
        raise MediaUnavailableError.new(url.to_s, "stream is unavailable (#{ex.status.code})")
      end

      final_url = response.url
      content_type = response.headers["Content-Type"]?.try(&.split(';').first.strip.downcase) || ""
      source = value["source"]?.try(&.as_h?)
      video = value["video"]?.try(&.as_h?)
      filesize = JsonValue.integer(source.try(&.["size"]?))

      source_type = JsonValue.string(source.try(&.["media_type"]?)) || ""
      source_name = JsonValue.string(source.try(&.["name"]?)) || ""
      if content_type.includes?("mpegurl") ||
         source_type.includes?("mpegurl") ||
         File.extname(final_url.path).downcase == ".m3u8" ||
         File.extname(source_name).downcase == ".m3u8"
        playlist = Extractors::Hls.new.extract(final_url, client, headers)
        return StreamFormats.new(playlist.formats, playlist.is_live?)
      end

      format = Format.new(
        format_id: "source",
        url: final_url,
        kind: stream_type == "audio" ? FormatKind::Audio : FormatKind::Combined,
        container: container_for(source, final_url),
        width: JsonValue.dimension(video.try(&.["width"]?)),
        height: JsonValue.dimension(video.try(&.["height"]?)),
        filesize: filesize,
        duration_seconds: duration_for(value, stream_type),
        headers: headers,
      )

      StreamFormats.new([format], false)
    end

    private def container_for(
      source : Hash(String, JSON::Any)?,
      url : URI,
    ) : String?
      mime = MimeType.parse(JsonValue.string(source.try(&.["media_type"]?)) || "")
      return mime.container unless mime.empty?

      name = JsonValue.string(source.try(&.["name"]?))
      extension = name.try { |value| File.extname(value).lchop('.') } ||
                  File.extname(url.path).lchop('.')
      extension unless extension.empty?
    end

    private def duration_for(
      value : Hash(String, JSON::Any),
      stream_type : String,
    ) : Float64?
      media = value[stream_type]?.try(&.as_h?)
      JsonValue.seconds(media.try(&.["duration"]?))
    end

    private def uploader_for(item : Hash(String, JSON::Any)) : String?
      channel = item["signing_channel"]?.try(&.as_h?)
      channel_value = channel.try(&.["value"]?).try(&.as_h?)

      JsonValue.string(channel_value.try(&.["title"]?)) ||
        JsonValue.string(channel.try(&.["name"]?))
    end

    private def thumbnail_for(value : Hash(String, JSON::Any)) : URI?
      thumbnail = value["thumbnail"]?.try(&.as_h?)
      HttpUrl.absolute(JsonValue.string(thumbnail.try(&.["url"]?)))
    end

    private def upload_date_for(item : Hash(String, JSON::Any)) : String?
      seconds = JsonValue.integer(item["timestamp"]?)
      return nil unless seconds && seconds > 0 && seconds < 253_402_300_800

      Time.unix(seconds).to_s("%Y-%m-%d")
    end
  end
end
