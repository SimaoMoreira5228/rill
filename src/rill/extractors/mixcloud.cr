require "base64"
require "json"
require "uri"

require "../errors"
require "../extractor"
require "../format"
require "../http_url"
require "../json_value"
require "../media"

module Rill::Extractors
  class Mixcloud < Extractor
    DEFAULT_API_BASE = "https://app.mixcloud.com"
    PATH             = %r{\A/([^/]+)/([^/]+)/?\z}
    ISO_DATE         = /\A\d{4}-\d{2}-\d{2}/
    DECRYPTION_KEY   = "IFYOUWANTTHEARTISTSTOGETPAIDDONOTDOWNLOADFROMMIXCLOUD"
    FIELDS           = "name description audioLength publishDate restrictedReason " \
                       "picture(width: 1024, height: 1024) { url } " \
                       "owner { displayName username url } " \
                       "streamInfo { url hlsUrl dashUrl }"

    RESERVED_SLUGS = %w(stream uploads favorites listens playlists)

    def initialize(@api_base : String = DEFAULT_API_BASE)
      @api_base = @api_base.rstrip('/')
    end

    def name : String
      "mixcloud"
    end

    def matches?(url : URI) : Bool
      return false unless url.scheme == "http" || url.scheme == "https"

      case url.host.try(&.downcase)
      when "mixcloud.com", "www.mixcloud.com", "beta.mixcloud.com", "m.mixcloud.com"
        !lookup(url.path).nil?
      else
        false
      end
    end

    def extract(url : URI, client : HTTPClient) : Media
      parts = lookup(url.path)
      unless parts
        raise UnsupportedUrlError.new(url.to_s)
      end

      username, slug = parts
      cloudcast = fetch_cloudcast(client, username, slug, url)
      check_restrictions(cloudcast, url)
      title = title(cloudcast, url)
      duration = JsonValue.seconds(cloudcast["audioLength"]?)
      format = audio_format(cloudcast, url, duration)

      Media.new(
        id: "#{username}_#{slug}",
        title: title,
        description: JsonValue.string(cloudcast["description"]?),
        webpage_url: url,
        uploader: uploader(cloudcast),
        duration_seconds: duration,
        thumbnail_url: thumbnail_url(cloudcast),
        upload_date: upload_date(cloudcast),
        extractor: name,
        formats: [format],
      )
    end

    private def lookup(path : String) : Tuple(String, String)?
      match = PATH.match(path)
      return nil unless match

      username = match[1]
      slug = match[2]
      return nil if RESERVED_SLUGS.includes?(slug.downcase)

      {username, slug}
    end

    private def fetch_cloudcast(
      client : HTTPClient,
      username : String,
      slug : String,
      url : URI,
    ) : Hash(String, JSON::Any)
      query = <<-GRAPHQL
        {
          cloudcastLookup(lookup: {username: #{username.to_json}, slug: #{slug.to_json}}) {
            #{FIELDS}
          }
        }
        GRAPHQL

      endpoint = URI.parse("#{@api_base}/graphql")
      endpoint.query = URI::Params.encode({"query" => query})
      response = client.get(endpoint)
      payload = JSON.parse(response.body)
      data = payload["data"]?.try(&.as_h?)
      cloudcast = data.try { |hash| hash["cloudcastLookup"]?.try(&.as_h?) }
      unless cloudcast
        raise MediaUnavailableError.new(url.to_s, "cloudcast was not found")
      end

      cloudcast
    rescue JSON::ParseException
      raise MediaUnavailableError.new(url.to_s, "GraphQL response is not valid JSON")
    rescue ex : HTTPError
      raise MediaUnavailableError.new(url.to_s, "cloudcast was not found") if ex.status.code == 404

      raise ex
    end

    private def check_restrictions(cloudcast : Hash(String, JSON::Any), url : URI) : Nil
      reason = JsonValue.string(cloudcast["restrictedReason"]?)
      return if reason.nil? || reason.empty?

      case reason
      when "tracklist"
        raise MediaUnavailableError.new(url.to_s, "track is unavailable due to licensing restrictions")
      when "repeat_play"
        raise MediaUnavailableError.new(url.to_s, "play limit was reached")
      else
        raise MediaUnavailableError.new(url.to_s, "track is restricted")
      end
    end

    private def title(cloudcast : Hash(String, JSON::Any), url : URI) : String
      value = JsonValue.string(cloudcast["name"]?)
      unless value
        raise MediaUnavailableError.new(url.to_s, "cloudcast name is missing")
      end

      value
    end

    private def uploader(cloudcast : Hash(String, JSON::Any)) : String?
      owner = cloudcast["owner"]?.try(&.as_h?)
      return nil unless owner

      JsonValue.string(owner["displayName"]?) || JsonValue.string(owner["username"]?)
    end

    private def thumbnail_url(cloudcast : Hash(String, JSON::Any)) : URI?
      picture = cloudcast["picture"]?.try(&.as_h?)
      value = picture.try { |hash| JsonValue.string(hash["url"]?) }
      HttpUrl.absolute(value)
    end

    private def upload_date(cloudcast : Hash(String, JSON::Any)) : String?
      value = JsonValue.string(cloudcast["publishDate"]?)
      return nil unless value
      return value[0, 10] if ISO_DATE.match(value)

      nil
    end

    private def audio_format(
      cloudcast : Hash(String, JSON::Any),
      url : URI,
      duration : Float64?,
    ) : Format
      info = cloudcast["streamInfo"]?.try(&.as_h?)
      if info
        if stream_url = decrypt_stream_url(info["url"]?)
          return stream_format("progressive", FormatProtocol::Http, stream_url, duration)
        end

        if stream_url = decrypt_stream_url(info["hlsUrl"]?)
          return stream_format("hls", FormatProtocol::Hls, stream_url, duration)
        end

        if stream_url = decrypt_stream_url(info["dashUrl"]?)
          return stream_format("dash", FormatProtocol::Dash, stream_url, duration)
        end
      end

      raise MediaUnavailableError.new(url.to_s, "cloudcast has no playable stream")
    end

    private def decrypt_stream_url(value : JSON::Any?) : URI?
      encoded = JsonValue.string(value)
      return nil unless encoded

      cipher = Base64.decode(encoded)
      plain = String.build(cipher.size) do |io|
        cipher.each_with_index do |byte, index|
          io.write_byte(byte ^ DECRYPTION_KEY.to_slice[index % DECRYPTION_KEY.bytesize])
        end
      end

      HttpUrl.absolute(plain)
    rescue Base64::Error
      nil
    end

    private def stream_format(
      format_id : String,
      protocol : FormatProtocol,
      stream_url : URI,
      duration : Float64?,
    ) : Format
      Format.new(
        format_id: format_id,
        url: stream_url,
        kind: FormatKind::Audio,
        protocol: protocol,
        container: "m4a",
        duration_seconds: duration,
      )
    end
  end
end
