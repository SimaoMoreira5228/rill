require "html"
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
  class Rumble < Extractor
    DEFAULT_BASE_URL  = "https://rumble.com"
    NORMAL_PATH       = %r{\A/(v(?!ideos\b)[A-Za-z0-9]+)(?:-[^/]*)?(?:\.html)?/?\z}
    EMBED_PATH        = %r{\A/embed/(v[A-Za-z0-9]+)/?\z}
    EMBED_REFERENCE   = %r{(?:(?:https?:)?//(?:www\.)?rumble\.com)?/embed/(v[A-Za-z0-9]+)}i
    TITLE_PATTERN     = %r{<title[^>]*>(.*?)</title>}mi
    TITLE_AUTHOR      = /\A.+?\s-\s([^-]+?)\s-\sRumble\z/i
    ARTIST_PATTERN    = /"content_artist"\s*:\s*"((?:\\.|[^"\\])*)"/
    THUMBNAIL_PATTERN = /"i"\s*:\s*"((?:\\.|[^"\\])*)"/
    DURATION_PATTERN  = /"duration"\s*:\s*(\d+)/

    def initialize(@base_url : String = DEFAULT_BASE_URL)
      @base_url = @base_url.rstrip('/')
    end

    def name : String
      "rumble"
    end

    def matches?(url : URI) : Bool
      return false unless url.scheme == "http" || url.scheme == "https"
      return false unless host?(url.host)

      !identifier_for(url).nil?
    end

    def extract(url : URI, client : HTTPClient) : Media
      identifier = identifier_for(url)
      unless identifier
        raise UnsupportedUrlError.new(url.to_s)
      end

      embed_id = embed_identifier(url, client)
      embed_url = URI.parse("#{@base_url}/embed/#{embed_id}")
      body = fetch(client, embed_url, url)
      config = config_for(body, embed_id)
      raw_title = raw_title(body)

      formats = formats_from(config)
      if formats.empty?
        raise MediaUnavailableError.new(url.to_s, "no playable variants were found")
      end

      Media.new(
        id: embed_id,
        title: title_for(raw_title, embed_id),
        webpage_url: url,
        uploader: uploader_for(body, raw_title),
        duration_seconds: duration_for(config, body),
        thumbnail_url: thumbnail_for(config, body),
        extractor: name,
        formats: formats,
      )
    end

    private def identifier_for(url : URI) : String?
      path = url.path
      match = NORMAL_PATH.match(path) || EMBED_PATH.match(path)
      match.try(&.[1])
    end

    private def embed_identifier(url : URI, client : HTTPClient) : String
      identifier = identifier_for(url).not_nil!
      return identifier if EMBED_PATH.match(url.path)

      body = fetch(client, url, url)
      match = EMBED_REFERENCE.match(body)
      unless match
        raise MediaUnavailableError.new(url.to_s, "page has no embed URL")
      end

      match[1]
    end

    private def fetch(client : HTTPClient, url : URI, original_url : URI) : String
      client.get(url).body
    rescue ex : HTTPError
      if ex.status.code == 404 || ex.status.code == 410
        raise MediaUnavailableError.new(original_url.to_s, "page is unavailable (#{ex.status.code})")
      end

      raise ex
    end

    private def host?(host : String?) : Bool
      case host.try(&.downcase)
      when "rumble.com", "www.rumble.com"
        true
      else
        false
      end
    end

    private def raw_title(body : String) : String
      match = TITLE_PATTERN.match(body)
      match ? HTML.unescape(match[1]).strip : ""
    end

    private def title_for(raw_title : String, identifier : String) : String
      title = raw_title.sub(/\s*-\s*Rumble\z/i, "").strip
      title.empty? ? identifier : title
    end

    private def uploader_for(body : String, raw_title : String) : String?
      if match = ARTIST_PATTERN.match(body)
        artist = json_unescape(match[1])
        return artist unless artist.try(&.empty?)
      end

      title_author(raw_title)
    end

    private def title_author(raw_title : String) : String?
      match = TITLE_AUTHOR.match(raw_title)
      return nil unless match

      author = HTML.unescape(match[1]).strip
      author.empty? ? nil : author
    end

    private def thumbnail_for(config : Hash(String, JSON::Any)?, body : String) : URI?
      value = config.try { |hash| JsonValue.string(hash["i"]?) }

      unless value
        if match = THUMBNAIL_PATTERN.match(body)
          value = json_unescape(match[1])
        end
      end

      value ? HttpUrl.absolute(value) : nil
    end

    private def duration_for(config : Hash(String, JSON::Any)?, body : String) : Float64?
      if config
        duration = JsonValue.seconds(config["duration"]?)
        return duration if duration
      end

      match = DURATION_PATTERN.match(body)
      return nil unless match

      match[1].to_f64?
    end

    private def config_for(body : String, identifier : String) : Hash(String, JSON::Any)?
      marker = "p.f[#{identifier.to_json}]"
      marker_index = body.index(marker)
      return nil unless marker_index

      equals_index = body.index('=', marker_index + marker.size)
      return nil unless equals_index

      object_start = body.index('{', equals_index)
      return nil unless object_start

      object_end = matching_brace(body, object_start)
      return nil unless object_end

      json = body[object_start..object_end].sub(/,\s*"?loaded"?\s*:\s*v\(\)(?=\s*\})/, "")
      JSON.parse(json).as_h?
    rescue JSON::ParseException
      nil
    end

    private def matching_brace(body : String, start : Int32) : Int32?
      depth = 0
      in_string = false
      escaped = false
      index = start

      while index < body.size
        char = body[index]

        if in_string
          if escaped
            escaped = false
          elsif char == '\\'
            escaped = true
          elsif char == '"'
            in_string = false
          end
        else
          case char
          when '"'
            in_string = true
          when '{'
            depth += 1
          when '}'
            depth -= 1
            return index if depth.zero?
          end
        end

        index += 1
      end

      nil
    end

    private def formats_from(config : Hash(String, JSON::Any)?) : Array(Format)
      formats = [] of Format
      return formats unless config

      seen_urls = Set(String).new
      seen_ids = Set(String).new

      if ua = config["ua"]?.try(&.as_h?)
        ua.each do |container, qualities_value|
          next unless supported_container?(container)

          qualities = qualities_value.as_h?
          next unless qualities

          qualities.each do |quality, entry_value|
            entry = entry_value.as_h?
            next unless entry

            append_variant(formats, seen_urls, seen_ids, entry, container, quality, false)
          end
        end
      end

      if base = config["u"]?.try(&.as_h?)
        base.each do |container, entry_value|
          next unless supported_container?(container)

          entry = entry_value.as_h?
          next unless entry

          append_variant(formats, seen_urls, seen_ids, entry, container, nil, true)
        end
      end

      formats
    end

    private def supported_container?(container : String) : Bool
      container == "mp4" || container == "webm"
    end

    private def append_variant(
      formats : Array(Format),
      seen_urls : Set(String),
      seen_ids : Set(String),
      entry : Hash(String, JSON::Any),
      container : String,
      quality : String?,
      base : Bool,
    ) : Nil
      url_text = JsonValue.string(entry["url"]?)
      return unless url_text

      url = HttpUrl.absolute(url_text)
      return unless url

      url_key = url.to_s
      return if seen_urls.includes?(url_key)

      meta = entry["meta"]?.try(&.as_h?) || {} of String => JSON::Any
      format_id = variant_id(seen_ids, container, quality, meta, base)

      seen_urls << url_key
      seen_ids << format_id
      formats << Format.new(
        format_id: format_id,
        url: url,
        kind: FormatKind::Combined,
        protocol: FormatProtocol::Http,
        container: container,
        bitrate: non_negative(JsonValue.integer(meta["bitrate"]?)),
        width: JsonValue.dimension(meta["w"]?),
        height: JsonValue.dimension(meta["h"]?),
        filesize: non_negative(JsonValue.integer(meta["size"]?)),
        note: base ? "base" : nil,
      )
    end

    private def variant_id(
      seen_ids : Set(String),
      container : String,
      quality : String?,
      meta : Hash(String, JSON::Any),
      base : Bool,
    ) : String
      suffix = if base
                 "base"
               else
                 quality || JsonValue.dimension(meta["h"]?).try(&.to_s) || "video"
               end

      candidate = "#{container}-#{suffix}"
      return candidate unless seen_ids.includes?(candidate)

      index = 2
      while seen_ids.includes?("#{candidate}-#{index}")
        index += 1
      end

      "#{candidate}-#{index}"
    end

    private def non_negative(value : Int64?) : Int64?
      value if value && value >= 0
    end

    private def json_unescape(value : String) : String?
      JSON.parse(%("#{value}")).as_s?
    rescue JSON::ParseException
      nil
    end
  end
end
