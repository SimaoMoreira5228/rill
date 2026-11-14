require "http/params"
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
  class TwitchClip < Extractor
    DEFAULT_ENDPOINT  = "https://gql.twitch.tv/gql"
    CLIENT_ID         = "ue6666qo983tsx6so1t0vnawi233wa"
    OPERATION_HASH    = "2db6a3b20eabf510bd3cf465ae2408834b59eb6b8af89ca73ab1486cacecfb63"
    SLUG_PATTERN      = /\A[A-Za-z0-9_-]+\z/
    CLIP_PATH         = %r{\A/([A-Za-z0-9_-]+)/?\z}
    CHANNEL_CLIP_PATH = %r{\A/[^/]+/clip/([A-Za-z0-9_-]+)/?\z}

    def initialize(@endpoint : String = DEFAULT_ENDPOINT)
    end

    def name : String
      "twitch_clip"
    end

    def matches?(url : URI) : Bool
      return false unless url.scheme == "http" || url.scheme == "https"

      !identifier_for(url).nil?
    end

    def extract(url : URI, client : HTTPClient) : Media
      slug = identifier_for(url)
      unless slug
        raise UnsupportedUrlError.new(url.to_s)
      end

      clip = clip_data(slug, client, url)
      formats = formats_from(clip)

      if formats.empty?
        raise MediaUnavailableError.new(url.to_s, "no playable formats were found")
      end

      Media.new(
        id: JsonValue.string(clip["id"]?) || slug,
        title: JsonValue.string(clip["title"]?) || slug,
        webpage_url: url,
        uploader: uploader_for(clip),
        duration_seconds: JsonValue.seconds(clip["duration"]?),
        thumbnail_url: thumbnail_for(clip),
        upload_date: upload_date_for(clip),
        extractor: name,
        formats: formats,
      )
    end

    private def identifier_for(url : URI) : String?
      if clips_host?(url.host)
        clips_identifier(url)
      elsif twitch_host?(url.host)
        channel_identifier(url)
      end
    end

    private def clips_identifier(url : URI) : String?
      return embed_identifier(url) if url.path == "/embed"

      slug = CLIP_PATH.match(url.path).try(&.[1])
      return nil if slug == "embed"

      slug
    end

    private def embed_identifier(url : URI) : String?
      slug = HTTP::Params.parse(url.query || "")["clip"]?
      return nil unless slug

      slug if SLUG_PATTERN.matches?(slug)
    end

    private def channel_identifier(url : URI) : String?
      CHANNEL_CLIP_PATH.match(url.path).try(&.[1])
    end

    private def clips_host?(host : String?) : Bool
      host.try(&.downcase) == "clips.twitch.tv"
    end

    private def twitch_host?(host : String?) : Bool
      case host.try(&.downcase)
      when "twitch.tv", "www.twitch.tv", "go.twitch.tv", "m.twitch.tv"
        true
      else
        false
      end
    end

    private def clip_data(
      slug : String,
      client : HTTPClient,
      url : URI,
    ) : Hash(String, JSON::Any)
      response = client.post(@endpoint, request_body(slug), request_headers)
      clip = parsed_clip(response.body)

      unless clip
        raise MediaUnavailableError.new(url.to_s, "clip is unavailable")
      end

      clip
    rescue JSON::ParseException
      raise MediaUnavailableError.new(url.to_s, "clip response is not valid JSON")
    end

    private def request_headers : HTTP::Headers
      headers = HTTP::Headers.new
      headers["Client-ID"] = CLIENT_ID
      headers["Content-Type"] = "text/plain;charset=UTF-8"
      headers
    end

    private def request_body(slug : String) : String
      JSON.build do |json|
        json.array do
          json.object do
            json.field "operationName", "ShareClipRenderStatus"
            json.field "variables" do
              json.object do
                json.field "slug", slug
              end
            end
            json.field "extensions" do
              json.object do
                json.field "persistedQuery" do
                  json.object do
                    json.field "version", 1
                    json.field "sha256Hash", OPERATION_HASH
                  end
                end
              end
            end
          end
        end
      end
    end

    private def parsed_clip(body : String) : Hash(String, JSON::Any)?
      payload = JSON.parse(body).as_a?
      return nil unless payload

      element = payload.first?.try(&.as_h?)
      return nil unless element

      data = element["data"]?.try(&.as_h?)
      return nil unless data

      data["clip"]?.try(&.as_h?)
    end

    private def formats_from(clip : Hash(String, JSON::Any)) : Array(Format)
      token = clip["playbackAccessToken"]?.try(&.as_h?)
      signature = JsonValue.string(token.try(&.["signature"]?))
      value = JsonValue.string(token.try(&.["value"]?))
      return [] of Format unless signature && value

      formats = [] of Format
      seen = Set(String).new
      assets = clip["assets"]?.try(&.as_a?) || [] of JSON::Any

      assets.each_with_index do |asset_value, index|
        asset = asset_value.as_h?
        next unless asset

        append_asset(formats, seen, asset, index == 1, signature, value)
      end

      formats
    end

    private def append_asset(
      formats : Array(Format),
      seen : Set(String),
      asset : Hash(String, JSON::Any),
      portrait : Bool,
      signature : String,
      token : String,
    ) : Nil
      qualities = asset["videoQualities"]?.try(&.as_a?) || [] of JSON::Any

      qualities.each do |quality_value|
        quality = quality_value.as_h?
        next unless quality

        source_url = JsonValue.string(quality["sourceURL"]?)
        signed_url = sign_url(source_url, signature, token)
        next unless signed_url

        url_key = signed_url.to_s
        next if seen.includes?(url_key)

        quality_label = JsonValue.string(quality["quality"]?)
        next unless quality_label

        seen << url_key
        formats << Format.new(
          format_id: portrait ? "portrait-#{quality_label}" : quality_label,
          url: signed_url,
          kind: FormatKind::Combined,
          protocol: FormatProtocol::Http,
          container: "mp4",
          height: height_for(quality_label),
          fps: fps_for(quality),
        )
      end
    end

    private def sign_url(source_url : String?, signature : String, token : String) : URI?
      url = HttpUrl.absolute(source_url)
      return nil unless url

      params = HTTP::Params.parse(url.query || "")
      params["sig"] = signature
      params["token"] = token
      url.query = params.to_s
      url
    rescue URI::Error
      nil
    end

    private def height_for(quality : String) : Int32?
      height = quality.to_i?
      height if height && height > 0
    end

    private def fps_for(quality : Hash(String, JSON::Any)) : Float64?
      fps = JsonValue.number(quality["frameRate"]?)
      fps if fps && fps > 0
    end

    private def thumbnail_for(clip : Hash(String, JSON::Any)) : URI?
      asset = clip["assets"]?.try(&.as_a?).try(&.first?).try(&.as_h?)
      return nil unless asset

      HttpUrl.absolute(JsonValue.string(asset["thumbnailURL"]?))
    end

    private def uploader_for(clip : Hash(String, JSON::Any)) : String?
      curator = clip["curator"]?.try(&.as_h?)
      uploader = presence(JsonValue.string(curator.try(&.["displayName"]?))) ||
                 presence(JsonValue.string(curator.try(&.["login"]?)))
      return uploader if uploader

      broadcaster = clip["broadcaster"]?.try(&.as_h?)
      presence(JsonValue.string(broadcaster.try(&.["displayName"]?)))
    end

    private def presence(value : String?) : String?
      value if value && !value.empty?
    end

    private def upload_date_for(clip : Hash(String, JSON::Any)) : String?
      created_at = JsonValue.string(clip["createdAt"]?)
      return nil unless created_at && created_at.size >= 10

      date = created_at[0, 10]
      date if /\A\d{4}-\d{2}-\d{2}\z/.matches?(date)
    end
  end
end
