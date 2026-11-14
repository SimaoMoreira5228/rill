require "html"
require "json"
require "time"
require "uri"

require "../errors"
require "../extractor"
require "../format"
require "../http_url"
require "../json_value"
require "../media"
require "../playlist"

module Rill::Extractors
  class Bandcamp < Extractor
    HOST     = /\A[a-z0-9-]+\.bandcamp\.com\z/i
    PATH     = %r{\A/(track|album)/([^/]+)/?\z}
    ISO_DATE = /\A\d{4}-\d{2}-\d{2}/
    DATE     = "%d %b %Y %H:%M:%S GMT"
    TRALBUM  = /data-tralbum\s*=\s*(?:"([^"]*)"|'([^']*)')/m
    OG_IMAGE = /\bproperty\s*=\s*(?:"og:image"|'og:image')/i
    CONTENT  = /\bcontent\s*=\s*(?:"([^"]*)"|'([^']*)')/i

    def name : String
      "bandcamp"
    end

    def matches?(url : URI) : Bool
      return false unless http_url?(url)
      return false unless artist_host?(url.host)

      !PATH.match(url.path).nil?
    end

    def extract(url : URI, client : HTTPClient) : Media | Playlist
      match = PATH.match(url.path)
      unless match
        raise UnsupportedUrlError.new(url.to_s)
      end

      response = fetch_page(client, url)
      tralbum = tralbum_data(response.body, url)

      if match[1] == "track"
        extract_track(url, tralbum, thumbnail_url(response.body, response.url))
      else
        extract_album(url, tralbum)
      end
    end

    private def http_url?(url : URI) : Bool
      url.scheme == "http" || url.scheme == "https"
    end

    private def artist_host?(host : String?) : Bool
      return false unless host

      name = host.downcase
      return false if name == "www.bandcamp.com"

      !HOST.match(name).nil?
    end

    private def fetch_page(client : HTTPClient, url : URI) : HTTPClient::Response
      client.get(url)
    rescue ex : HTTPError
      if ex.status.code == 404
        raise MediaUnavailableError.new(url.to_s, "page not found")
      end

      raise ex
    end

    private def tralbum_data(body : String, url : URI) : Hash(String, JSON::Any)
      attribute = tralbum_attribute(body)
      unless attribute
        raise MediaUnavailableError.new(url.to_s, "page has no data-tralbum attribute")
      end

      payload = JSON.parse(HTML.unescape(attribute)).as_h?
      unless payload
        raise MediaUnavailableError.new(url.to_s, "data-tralbum is not a JSON object")
      end

      payload
    rescue JSON::ParseException
      raise MediaUnavailableError.new(url.to_s, "data-tralbum is not valid JSON")
    end

    private def tralbum_attribute(body : String) : String?
      match = TRALBUM.match(body)
      return nil unless match

      match[1]? || match[2]?
    end

    private def extract_track(
      url : URI,
      tralbum : Hash(String, JSON::Any),
      thumbnail : URI?,
    ) : Media
      if tralbum["is_private_stream"]?.try(&.as_bool?)
        raise MediaUnavailableError.new(url.to_s, "track stream is private")
      end

      current = tralbum["current"]?.try(&.as_h?) || {} of String => JSON::Any
      track = first_track(tralbum, url)

      if track["private"]?.try(&.as_bool?)
        raise MediaUnavailableError.new(url.to_s, "track is private")
      end

      title = JsonValue.string(current["title"]?) || JsonValue.string(track["title"]?)
      unless title
        raise MediaUnavailableError.new(url.to_s, "track title is missing")
      end

      duration = JsonValue.seconds(track["duration"]?)
      format = audio_format(track, url, duration)

      Media.new(
        id: track_id(track) || JsonValue.string(tralbum["id"]?),
        title: title,
        description: JsonValue.string(current["about"]?),
        webpage_url: url,
        uploader: JsonValue.string(tralbum["artist"]?) || JsonValue.string(current["artist"]?),
        duration_seconds: duration,
        thumbnail_url: thumbnail,
        upload_date: upload_date(current),
        extractor: name,
        formats: [format],
      )
    end

    private def first_track(
      tralbum : Hash(String, JSON::Any),
      url : URI,
    ) : Hash(String, JSON::Any)
      tracks = tralbum["trackinfo"]?.try(&.as_a?)
      unless tracks
        raise MediaUnavailableError.new(url.to_s, "page has no trackinfo")
      end

      track = tracks.first?.try(&.as_h?)
      unless track
        raise MediaUnavailableError.new(url.to_s, "track data is missing")
      end

      track
    end

    private def audio_format(
      track : Hash(String, JSON::Any),
      url : URI,
      duration : Float64?,
    ) : Format
      file = track["file"]?.try(&.as_h?)
      value = file.try { |hash| JsonValue.string(hash["mp3-128"]?) }
      unless value
        raise MediaUnavailableError.new(url.to_s, "stream is unavailable")
      end

      stream_url = HttpUrl.absolute(protocol_url(value))
      unless stream_url
        raise MediaUnavailableError.new(url.to_s, "stream URL is invalid")
      end

      Format.new(
        format_id: "mp3-128",
        url: stream_url,
        kind: FormatKind::Audio,
        container: "mp3",
        bitrate: 128_000_i64,
        duration_seconds: duration,
      )
    end

    private def protocol_url(value : String) : String
      value.starts_with?("//") ? "https:#{value}" : value
    end

    private def extract_album(
      page_url : URI,
      tralbum : Hash(String, JSON::Any),
    ) : Playlist
      current = tralbum["current"]?.try(&.as_h?) || {} of String => JSON::Any
      title = JsonValue.string(current["title"]?)
      unless title
        raise MediaUnavailableError.new(page_url.to_s, "album title is missing")
      end

      entries = album_entries(tralbum["trackinfo"]?, page_url)
      if entries.empty?
        raise MediaUnavailableError.new(page_url.to_s, "album has no tracks")
      end

      Playlist.new(
        id: JsonValue.string(current["id"]?),
        title: title,
        webpage_url: page_url,
        extractor: name,
        entries: entries,
      )
    end

    private def album_entries(
      value : JSON::Any?,
      page_url : URI,
    ) : Array(PlaylistEntry)
      tracks = value.try(&.as_a?)
      return [] of PlaylistEntry unless tracks

      entries = [] of PlaylistEntry
      tracks.each do |item|
        track = item.as_h?
        next unless track

        title_link = JsonValue.string(track["title_link"]?)
        next unless title_link

        entry_url = HttpUrl.resolve(page_url, title_link)
        next unless entry_url

        entries << PlaylistEntry.new(
          url: entry_url,
          title: JsonValue.string(track["title"]?),
          id: track_id(track),
        )
      end

      entries
    end

    private def track_id(track : Hash(String, JSON::Any)) : String?
      JsonValue.string(track["id"]?) || JsonValue.string(track["track_id"]?)
    end

    private def upload_date(current : Hash(String, JSON::Any)) : String?
      value = JsonValue.string(current["release_date"]?) || JsonValue.string(current["publish_date"]?)
      return nil unless value
      return value[0, 10] if ISO_DATE.match(value)

      Time.parse(value, DATE, Time::Location::UTC).to_s("%Y-%m-%d")
    rescue Time::Format::Error
      nil
    end

    private def thumbnail_url(body : String, base_url : URI) : URI?
      body.scan(/<meta\b[^>]*>/i) do |match|
        meta = match[0]
        next unless OG_IMAGE.match(meta)

        content = CONTENT.match(meta)
        next unless content

        value = content[1]? || content[2]?
        next unless value

        return HttpUrl.resolve(base_url, HTML.unescape(value))
      end

      nil
    end
  end
end
