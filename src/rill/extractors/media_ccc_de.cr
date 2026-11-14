require "json"
require "uri"

require "../errors"
require "../extractor"
require "../format"
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
        id: scalar_string(payload["guid"]?),
        title: scalar_string(payload["title"]?) || slug,
        description: scalar_string(payload["description"]?),
        webpage_url: url,
        uploader: persons(payload["persons"]?),
        duration_seconds: parse_seconds(payload["duration"]?),
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
          title: scalar_string(event_hash["title"]?),
          id: scalar_string(event_hash["guid"]?),
        )
      end

      if entries.empty?
        raise MediaUnavailableError.new(url.to_s, "conference has no events")
      end

      Playlist.new(
        id: acronym,
        title: scalar_string(payload["title"]?) || acronym,
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

        filename = scalar_string(recording_hash["filename"]?)
        next unless filename

        recording_url = parse_uri(scalar_string(recording_hash["recording_url"]?))
        next unless recording_url

        mime_type = scalar_string(recording_hash["mime_type"]?) || ""
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
          width: dimension(recording_hash["width"]?),
          height: dimension(recording_hash["height"]?),
          language: scalar_string(recording_hash["language"]?),
          note: mime_type,
        )
      end

      formats
    end

    private def dimension(value : JSON::Any?) : Int32?
      number = value.try(&.as_i64?)
      return nil unless number && 0 < number <= 100_000

      number.to_i32
    end

    private def persons(value : JSON::Any?) : String?
      array = value.try(&.as_a?)
      return nil unless array

      names = array.compact_map(&.as_s?)
      names.empty? ? nil : names.join(", ")
    end

    private def event_url(event : Hash(String, JSON::Any)) : URI?
      value = scalar_string(event["frontend_link"]?) || scalar_string(event["link"]?)

      if value.nil?
        slug = scalar_string(event["slug"]?)
        value = "#{DEFAULT_API_BASE}/v/#{URI.encode_path_segment(slug)}" if slug
      end

      return nil unless value
      value = value.sub("/public/events/", "/v/")
      parse_uri(value)
    end

    private def thumbnail_url(payload : Hash(String, JSON::Any)) : URI?
      value = scalar_string(payload["thumb_url"]?) || scalar_string(payload["poster_url"]?)
      value ? parse_uri(value) : nil
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

    private def date_value(payload : Hash(String, JSON::Any)) : String?
      value = scalar_string(payload["date"]?)
      return nil unless value
      return nil if value.size < 10

      value[0, 10]
    end

    private def parse_seconds(value : JSON::Any?) : Float64?
      seconds = scalar_string(value).try(&.to_f?)
      return nil unless seconds && seconds.finite? && seconds >= 0

      seconds
    end

    private def scalar_string(value : JSON::Any?) : String?
      return nil unless value

      if string = value.as_s?
        string
      elsif integer = value.as_i64?
        integer.to_s
      elsif float = value.as_f?
        float.to_s
      else
        nil
      end
    end
  end
end
