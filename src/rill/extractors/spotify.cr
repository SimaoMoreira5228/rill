require "json"
require "uri"

require "../errors"
require "../extractor"
require "../http_url"
require "../json_value"
require "../media"
require "./youtube"

module Rill::Extractors
  class Spotify < Extractor
    DEFAULT_API_BASE = "https://open.spotify.com"
    TRACK_PATH       = %r{\A/(?:intl-[a-z-]+/)?track/([A-Za-z0-9]{22})/?\z}
    USER_AGENT       = "Mozilla/5.0"

    def initialize(
      @api_base : String = DEFAULT_API_BASE,
      @youtube : YouTube = YouTube.new,
    )
    end

    def name : String
      "spotify"
    end

    def matches?(url : URI) : Bool
      return false unless url.scheme == "http" || url.scheme == "https"

      host = url.host.try(&.downcase)
      return false unless host == "open.spotify.com" || host == "www.open.spotify.com"

      !track_id_for(url).nil?
    end

    def extract(url : URI, client : HTTPClient) : Media
      track_id = track_id_for(url)
      unless track_id
        raise UnsupportedUrlError.new(url.to_s)
      end

      entity = fetch_entity(client, track_id, url)
      if entity["isPlayable"]?.try(&.as_bool?) == false
        raise MediaUnavailableError.new(url.to_s, "track is not playable")
      end

      title = JsonValue.string(entity["title"]?) || JsonValue.string(entity["name"]?) || track_id
      artists = artist_names(entity)
      duration = duration_seconds(entity)
      query = [title, artists].compact.join(" ").strip

      matches = @youtube.search(query, client, 10)
      if matches.empty?
        raise MediaUnavailableError.new(url.to_s, "could not find a YouTube match")
      end

      match = select_match(matches, duration)
      youtube_media = @youtube.extract(
        URI.parse("https://www.youtube.com/watch?v=#{match.video_id}"),
        client,
      )
      unless youtube_media.is_a?(Media)
        raise MediaUnavailableError.new(url.to_s, "YouTube match is not a single video")
      end

      warnings = [
        "Spotify provides no DRM-free stream; formats were resolved from YouTube: " \
        "#{match.title} (https://youtu.be/#{match.video_id}).",
      ]

      if duration && match.duration_seconds
        difference = (duration - match.duration_seconds.not_nil!).abs
        if difference > 15
          warnings << "The matched YouTube duration differs by #{difference.round.to_i} seconds; verify the result."
        end
      end

      Media.new(
        id: track_id,
        title: title,
        webpage_url: url,
        uploader: artists,
        duration_seconds: duration,
        thumbnail_url: thumbnail_url(entity),
        upload_date: release_date(entity),
        extractor: name,
        formats: youtube_media.formats,
        warnings: warnings,
      )
    end

    private def fetch_entity(client : HTTPClient, track_id : String, url : URI) : Hash(String, JSON::Any)
      headers = HTTP::Headers.new
      headers["User-Agent"] = USER_AGENT
      headers["Accept-Language"] = "en-US,en;q=0.9"

      response = client.get("#{@api_base}/embed/track/#{track_id}", headers)
      match = /<script id="__NEXT_DATA__" type="application\/json">(.*?)<\/script>/m.match(response.body)
      unless match
        raise MediaUnavailableError.new(url.to_s, "Spotify embed data is missing")
      end

      payload = JSON.parse(match[1])
      entity = dig(payload, ["props", "pageProps", "state", "data", "entity"]).try(&.as_h?)
      unless entity
        raise MediaUnavailableError.new(url.to_s, "Spotify track data is missing")
      end

      entity
    rescue JSON::ParseException
      raise MediaUnavailableError.new(url.to_s, "Spotify embed data is not valid JSON")
    end

    private def track_id_for(url : URI) : String?
      match = TRACK_PATH.match(url.path)
      return nil unless match

      match[1]
    end

    private def artist_names(entity : Hash(String, JSON::Any)) : String?
      artists = entity["artists"]?.try(&.as_a?)
      return nil unless artists

      names = artists.compact_map do |artist|
        artist.as_h?.try { |hash| JsonValue.string(hash["name"]?) }
      end
      names.empty? ? nil : names.join(", ")
    end

    private def duration_seconds(entity : Hash(String, JSON::Any)) : Float64?
      milliseconds = entity["duration"]?.try(&.as_i64?)
      return nil unless milliseconds && milliseconds > 0

      milliseconds / 1000.0
    end

    private def release_date(entity : Hash(String, JSON::Any)) : String?
      release = entity["releaseDate"]?.try(&.as_h?)
      value = release.try { |hash| JsonValue.string(hash["isoString"]?) }
      return nil unless value
      return nil if value.size < 10

      value[0, 10]
    end

    private def thumbnail_url(entity : Hash(String, JSON::Any)) : URI?
      identity = entity["visualIdentity"]?.try(&.as_h?)
      images = identity.try { |hash| hash["image"]?.try(&.as_a?) }
      return nil unless images

      image = images.max_by? do |item|
        item.as_h?.try { |hash| hash["maxWidth"]?.try(&.as_i64?) } || 0_i64
      end
      return nil unless image

      value = image.as_h?.try { |hash| JsonValue.string(hash["url"]?) }
      HttpUrl.absolute(value)
    end

    private def select_match(
      matches : Array(YouTube::SearchResult),
      duration : Float64?,
    ) : YouTube::SearchResult
      return matches.first unless duration

      matches.min_by? do |match|
        if match_duration = match.duration_seconds
          (match_duration - duration).abs
        else
          Float64::MAX
        end
      end || matches.first
    end

    private def dig(value : JSON::Any?, keys : Array(String)) : JSON::Any?
      keys.each do |key|
        hash = value.try(&.as_h?)
        return nil unless hash

        value = hash[key]?
      end

      value
    end
  end
end
