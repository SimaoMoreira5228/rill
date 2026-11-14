require "json"
require "uri"

require "../errors"
require "../extractor"
require "../format"
require "../http_url"
require "../json_value"
require "../media"
require "../mime_type"

module Rill::Extractors
  class MediaCccDe < Extractor
    DEFAULT_API_BASE = "https://media.ccc.de"
    EVENT_PATH       = %r{\A/v/([^/]+)/?\z}
    CONFERENCE_PATH  = %r{\A/(?:c|conferences)/([^/]+)/?\z}

    def initialize(@api_base : String = DEFAULT_API_BASE)
    end

    def name : String
      "media_ccc_de"
    end

    def matches?(url : URI) : Bool
      return false unless url.scheme == "http" || url.scheme == "https"
      return false unless host?(url.host)

      path = url.path
      !EVENT_PATH.match(path).nil? || !CONFERENCE_PATH.match(path).nil?
    end

    def extract(url : URI, client : HTTPClient) : Media | Playlist
      if slug = slug_for(url, EVENT_PATH)
        extract_event(url, client, slug)
      elsif acronym = slug_for(url, CONFERENCE_PATH)
        extract_conference(url, client, acronym)
      else
        raise UnsupportedUrlError.new(url.to_s)
      end
    end

    private def extract_event(url : URI, client : HTTPClient, slug : String) : Media
      api_url = URI.parse("#{@api_base}/public/events/#{URI.encode_path_segment(slug)}")
      payload = api_payload(client, api_url, url, "event")

      formats = formats_from(payload["recordings"]?)
      if formats.empty?
        raise MediaUnavailableError.new(url.to_s, "event has no downloadable recordings")
      end

      Media.new(
        id: JsonValue.string(payload["guid"]?),
        title: JsonValue.string(payload["title"]?) || slug,
        description: JsonValue.string(payload["description"]?),
        webpage_url: url,
        uploader: persons(payload["persons"]?),
        duration_seconds: JsonValue.seconds(payload["duration"]?),
        thumbnail_url: thumbnail_url(payload),
        upload_date: date_value(payload),
        extractor: name,
        formats: formats,
      )
    end

    private def extract_conference(
      url : URI,
      client : HTTPClient,
      acronym : String,
    ) : Playlist
      api_url = URI.parse("#{@api_base}/public/conferences/#{URI.encode_path_segment(acronym)}")
      payload = api_payload(client, api_url, url, "conference")

      entries = [] of PlaylistEntry
      events = payload["events"]?.try(&.as_a?) || [] of JSON::Any

      events.each do |event|
        event_hash = event.as_h?
        next unless event_hash

        entry_url = event_url(event_hash)
        next unless entry_url

        entries << PlaylistEntry.new(
          url: entry_url,
          title: JsonValue.string(event_hash["title"]?),
          id: JsonValue.string(event_hash["guid"]?),
        )
      end

      if entries.empty?
        raise MediaUnavailableError.new(url.to_s, "conference has no events")
      end

      Playlist.new(
        id: acronym,
        title: JsonValue.string(payload["title"]?) || acronym,
        webpage_url: url,
        extractor: name,
        entries: entries,
      )
    end

    private def api_payload(
      client : HTTPClient,
      api_url : URI,
      url : URI,
      subject : String,
    ) : Hash(String, JSON::Any)
      response = client.get(api_url)
      parse_payload(response.body, url)
    rescue ex : HTTPError
      if ex.status.code == 404
        raise MediaUnavailableError.new(url.to_s, "#{subject} not found")
      end
      raise ex
    end

    private def host?(host : String?) : Bool
      case host.try(&.downcase)
      when "media.ccc.de", "www.media.ccc.de"
        true
      else
        false
      end
    end

    private def slug_for(url : URI, pattern : Regex) : String?
      match = pattern.match(url.path)
      return nil unless match

      slug = URI.decode(match[1])
      slug.empty? ? nil : slug
    end

    private def parse_payload(body : String, url : URI) : Hash(String, JSON::Any)
      payload = JSON.parse(body).as_h?
      unless payload
        raise MediaUnavailableError.new(url.to_s, "metadata is not a JSON object")
      end

      payload
    rescue JSON::ParseException
      raise MediaUnavailableError.new(url.to_s, "metadata is not valid JSON")
    end

    private def formats_from(recordings_value : JSON::Any?) : Array(Format)
      recordings = recordings_value.try(&.as_a?)
      return [] of Format unless recordings

      formats = [] of Format

      recordings.each do |recording|
        recording_hash = recording.as_h?
        next unless recording_hash

        filename = JsonValue.string(recording_hash["filename"]?)
        next unless filename

        recording_url = HttpUrl.absolute(JsonValue.string(recording_hash["recording_url"]?))
        next unless recording_url

        mime_type = JsonValue.string(recording_hash["mime_type"]?) || ""
        mime = MimeType.parse(mime_type)
        next if mime.empty?

        audio = mime.audio?
        formats << Format.new(
          format_id: filename,
          url: recording_url,
          kind: audio ? FormatKind::Audio : FormatKind::Combined,
          container: mime.container,
          video_codec: audio ? nil : mime.codecs,
          audio_codec: audio ? mime.audio_codec : nil,
          width: JsonValue.dimension(recording_hash["width"]?),
          height: JsonValue.dimension(recording_hash["height"]?),
          language: JsonValue.string(recording_hash["language"]?),
          note: mime_type,
        )
      end

      formats
    end

    private def persons(value : JSON::Any?) : String?
      array = value.try(&.as_a?)
      return nil unless array

      names = array.compact_map(&.as_s?)
      names.empty? ? nil : names.join(", ")
    end

    private def event_url(event : Hash(String, JSON::Any)) : URI?
      value = JsonValue.string(event["frontend_link"]?) || JsonValue.string(event["link"]?)

      if value.nil?
        slug = JsonValue.string(event["slug"]?)
        value = "#{DEFAULT_API_BASE}/v/#{URI.encode_path_segment(slug)}" if slug
      end

      return nil unless value
      value = value.sub("/public/events/", "/v/")
      HttpUrl.absolute(value)
    end

    private def thumbnail_url(payload : Hash(String, JSON::Any)) : URI?
      value = JsonValue.string(payload["thumb_url"]?) || JsonValue.string(payload["poster_url"]?)
      value ? HttpUrl.absolute(value) : nil
    end

    private def date_value(payload : Hash(String, JSON::Any)) : String?
      value = JsonValue.string(payload["date"]?)
      return nil unless value
      return nil if value.size < 10

      value[0, 10]
    end
  end
end
