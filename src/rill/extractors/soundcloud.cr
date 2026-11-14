require "json"
require "uri"

require "../errors"
require "../extractor"
require "../format"
require "../http_url"
require "../json_value"
require "../media"

module Rill::Extractors
  class SoundCloud < Extractor
    TRACK_PATH = %r{\A/([^/]+)/([^/]+)/?\z}
    SHORT_PATH = %r{\A/([^/]+)/?\z}
    HYDRATION  = /window\.__sc_hydration\s*=\s*(\[.*?\]);/m
    ISO_DATE   = /\A\d{4}-\d{2}-\d{2}/

    RESERVED_SEGMENTS = %w(
      albums artists charts comments creators discover download followers
      following jobs likes pages playlists popular recommended reposts
      search sets stream tracks upload you
    )

    HLS_PRESETS = {
      "aac_160k" => 30,
      "abr_sq"   => 20,
      "aac_96k"  => 10,
    }

    def name : String
      "soundcloud"
    end

    def matches?(url : URI) : Bool
      return false unless http_url?(url)

      case url.host.try(&.downcase)
      when "on.soundcloud.com"
        !SHORT_PATH.match(url.path).nil?
      when "soundcloud.com", "www.soundcloud.com"
        track_path?(url.path)
      else
        false
      end
    end

    def extract(url : URI, client : HTTPClient) : Media
      response = fetch_page(client, url)
      page_url = response.url

      unless track_path?(page_url.path)
        raise MediaUnavailableError.new(page_url.to_s, "link did not resolve to a track")
      end

      entries = hydration_entries(response.body, page_url)
      sound = hydration_data(entries, "sound", page_url)
      title = JsonValue.string(sound["title"]?)
      unless title
        raise MediaUnavailableError.new(page_url.to_s, "track title is missing")
      end

      duration = duration_seconds(sound)
      format = media_format(client, sound, entries, page_url, duration)

      Media.new(
        id: track_id(sound),
        title: title,
        description: JsonValue.string(sound["description"]?),
        webpage_url: page_url,
        uploader: uploader(sound),
        duration_seconds: duration,
        thumbnail_url: thumbnail_url(sound),
        upload_date: upload_date(sound),
        extractor: name,
        formats: [format],
      )
    end

    private def http_url?(url : URI) : Bool
      url.scheme == "http" || url.scheme == "https"
    end

    private def track_path?(path : String) : Bool
      match = TRACK_PATH.match(path)
      return false unless match

      user = match[1]
      slug = match[2]
      return false if user.empty? || slug.empty?
      return false if reserved?(user) || reserved?(slug)

      true
    end

    private def reserved?(segment : String) : Bool
      RESERVED_SEGMENTS.includes?(segment.downcase)
    end

    private def fetch_page(client : HTTPClient, url : URI) : HTTPClient::Response
      client.get(url)
    rescue ex : HTTPError
      if ex.status.code == 404
        raise MediaUnavailableError.new(url.to_s, "page not found")
      end

      raise ex
    end

    private def hydration_entries(body : String, url : URI) : Array(JSON::Any)
      match = HYDRATION.match(body)
      unless match
        raise MediaUnavailableError.new(url.to_s, "page has no hydration data")
      end

      entries = JSON.parse(match[1]).as_a?
      unless entries
        raise MediaUnavailableError.new(url.to_s, "hydration data is not a JSON array")
      end

      entries
    rescue JSON::ParseException
      raise MediaUnavailableError.new(url.to_s, "hydration data is not valid JSON")
    end

    private def hydration_data(
      entries : Array(JSON::Any),
      hydratable : String,
      url : URI,
    ) : Hash(String, JSON::Any)
      data = hydration_data?(entries, hydratable)
      unless data
        raise MediaUnavailableError.new(url.to_s, "#{hydratable} data is missing")
      end

      data
    end

    private def hydration_data?(
      entries : Array(JSON::Any),
      hydratable : String,
    ) : Hash(String, JSON::Any)?
      entries.each do |entry|
        hash = entry.as_h?
        next unless hash
        next unless JsonValue.string(hash["hydratable"]?) == hydratable

        return hash["data"]?.try(&.as_h?)
      end

      nil
    end

    private def media_format(
      client : HTTPClient,
      sound : Hash(String, JSON::Any),
      entries : Array(JSON::Any),
      url : URI,
      duration : Float64?,
    ) : Format
      transcodings = transcodings(sound, url)

      if progressive = progressive_transcoding(transcodings)
        return progressive_format(progressive, url, duration)
      end

      hls = best_hls_transcoding(transcodings)
      unless hls
        raise MediaUnavailableError.new(url.to_s, "track has no progressive or HLS stream")
      end

      hls_format(client, hls, entries, sound, url, duration)
    end

    private def transcodings(
      sound : Hash(String, JSON::Any),
      url : URI,
    ) : Array(Hash(String, JSON::Any))
      media = sound["media"]?.try(&.as_h?)
      values = media.try { |hash| hash["transcodings"]?.try(&.as_a?) }
      items = values.try(&.compact_map(&.as_h?)) || [] of Hash(String, JSON::Any)
      if items.empty?
        raise MediaUnavailableError.new(url.to_s, "track has no transcodings")
      end

      items
    end

    private def progressive_transcoding(
      transcodings : Array(Hash(String, JSON::Any)),
    ) : Hash(String, JSON::Any)?
      candidates = transcodings.select do |item|
        protocol(item) == "progressive" && !transcoding_url(item).nil? && !transcoding_preset(item).nil?
      end

      candidates.max_by? do |item|
        preset_bitrate(transcoding_preset(item).not_nil!) || 0
      end
    end

    private def best_hls_transcoding(
      transcodings : Array(Hash(String, JSON::Any)),
    ) : Hash(String, JSON::Any)?
      candidates = transcodings.select do |item|
        hls?(item) && !transcoding_url(item).nil? && !transcoding_preset(item).nil?
      end

      candidates.max_by? do |item|
        HLS_PRESETS[transcoding_preset(item).not_nil!]? || 0
      end
    end

    private def hls?(transcoding : Hash(String, JSON::Any)) : Bool
      value = protocol(transcoding)
      return true if value == "hls"
      return false if value.try(&.includes?("encrypted"))

      transcoding_url(transcoding).try(&.includes?("/hls")) || false
    end

    private def protocol(transcoding : Hash(String, JSON::Any)) : String?
      format = transcoding["format"]?.try(&.as_h?)
      format.try { |hash| JsonValue.string(hash["protocol"]?) }.try(&.downcase)
    end

    private def transcoding_url(transcoding : Hash(String, JSON::Any)) : String?
      JsonValue.string(transcoding["url"]?)
    end

    private def transcoding_preset(transcoding : Hash(String, JSON::Any)) : String?
      JsonValue.string(transcoding["preset"]?)
    end

    private def progressive_format(
      transcoding : Hash(String, JSON::Any),
      url : URI,
      duration : Float64?,
    ) : Format
      preset = transcoding_preset(transcoding).not_nil!
      stream_url = HttpUrl.absolute(transcoding_url(transcoding))
      unless stream_url
        raise MediaUnavailableError.new(url.to_s, "progressive stream URL is invalid")
      end

      Format.new(
        format_id: "progressive-#{preset}",
        url: stream_url,
        kind: FormatKind::Audio,
        container: "mp3",
        bitrate: preset_bitrate(preset),
        duration_seconds: duration,
        note: "progressive",
      )
    end

    private def hls_format(
      client : HTTPClient,
      transcoding : Hash(String, JSON::Any),
      entries : Array(JSON::Any),
      sound : Hash(String, JSON::Any),
      url : URI,
      duration : Float64?,
    ) : Format
      preset = transcoding_preset(transcoding).not_nil!
      endpoint = HttpUrl.absolute(transcoding_url(transcoding))
      unless endpoint
        raise MediaUnavailableError.new(url.to_s, "HLS stream URL is invalid")
      end

      client_id = api_client_id(entries)
      unless client_id
        raise MediaUnavailableError.new(url.to_s, "client id is missing from the page")
      end

      query = URI::Params.parse(endpoint.query || "")
      query["client_id"] = client_id
      if authorization = JsonValue.string(sound["track_authorization"]?)
        query["track_authorization"] = authorization
      end
      endpoint.query = query.to_s

      stream_url = resolve_stream_url(client, endpoint, url)
      Format.new(
        format_id: "hls-#{preset}",
        url: stream_url,
        kind: FormatKind::Audio,
        protocol: FormatProtocol::Hls,
        container: "m4a",
        bitrate: preset_bitrate(preset),
        duration_seconds: duration,
        note: "HLS",
      )
    end

    private def api_client_id(entries : Array(JSON::Any)) : String?
      client = hydration_data?(entries, "apiClient")
      client.try { |hash| JsonValue.string(hash["id"]?) }
    end

    private def resolve_stream_url(client : HTTPClient, endpoint : URI, url : URI) : URI
      response = client.get(endpoint)
      payload = JSON.parse(response.body).as_h?
      value = payload.try { |hash| JsonValue.string(hash["url"]?) }
      stream_url = HttpUrl.absolute(value)
      unless stream_url
        raise MediaUnavailableError.new(url.to_s, "HLS stream is unavailable")
      end

      stream_url
    rescue JSON::ParseException
      raise MediaUnavailableError.new(url.to_s, "HLS stream response is not valid JSON")
    end

    private def duration_seconds(sound : Hash(String, JSON::Any)) : Float64?
      milliseconds = JsonValue.number(sound["duration"]?)
      return nil unless milliseconds && milliseconds > 0

      milliseconds / 1000.0
    end

    private def uploader(sound : Hash(String, JSON::Any)) : String?
      user = sound["user"]?.try(&.as_h?)
      return nil unless user

      JsonValue.string(user["username"]?) || JsonValue.string(user["permalink"]?)
    end

    private def thumbnail_url(sound : Hash(String, JSON::Any)) : URI?
      value = JsonValue.string(sound["artwork_url"]?)
      return nil unless value

      value = value.sub("-large", "-t500x500") if value.includes?("-large")
      HttpUrl.absolute(value)
    end

    private def upload_date(sound : Hash(String, JSON::Any)) : String?
      values = [
        JsonValue.string(sound["display_date"]?),
        JsonValue.string(sound["created_at"]?),
      ]

      values.each do |value|
        next unless value
        next unless ISO_DATE.match(value)

        return value[0, 10]
      end

      nil
    end

    private def track_id(sound : Hash(String, JSON::Any)) : String?
      JsonValue.string(sound["id"]?) || urn_id(JsonValue.string(sound["urn"]?))
    end

    private def urn_id(urn : String?) : String?
      return nil unless urn

      id = urn.split(':').last?
      id && !id.empty? ? id : nil
    end

    private def preset_bitrate(preset : String) : Int64?
      match = /(\d+)k/.match(preset) || /_(\d+)\z/.match(preset)
      return nil unless match

      value = match[1].to_i64?
      value ? value * 1000 : nil
    end
  end
end
