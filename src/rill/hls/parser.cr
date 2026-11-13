require "uri"

require "../errors"
require "./playlist"

module Rill::Hls::Parser
  extend self

  STREAM_INF = "#EXT-X-STREAM-INF:"
  EXTINF     = "#EXTINF:"
  KEY        = "#EXT-X-KEY:"
  MAP        = "#EXT-X-MAP:"
  BYTERANGE  = "#EXT-X-BYTERANGE:"
  ENDLIST    = "#EXT-X-ENDLIST"

  def parse(source : String, base_url : URI) : MultivariantPlaylist | MediaPlaylist
    text = source.lchop('\uFEFF')
    lines = text.lines.map(&.strip).reject(&.empty?)

    unless lines.first? == "#EXTM3U"
      raise ManifestError.new("HLS playlist is missing #EXTM3U")
    end

    if lines.any?(&.starts_with?(STREAM_INF))
      parse_master(lines, base_url)
    else
      parse_media(lines, base_url)
    end
  end

  def parse_attributes(text : String) : Hash(String, String)
    attributes = {} of String => String
    index = 0

    while index < text.size
      while index < text.size && (text[index] == ' ' || text[index] == ',')
        index += 1
      end
      break if index >= text.size

      key_start = index
      while index < text.size && text[index] != '='
        index += 1
      end

      if index >= text.size
        raise ManifestError.new("invalid HLS attribute: #{text}")
      end

      key = text[key_start, index - key_start].strip
      index += 1

      value = if index < text.size && text[index] == '"'
                index += 1
                value_start = index
                while index < text.size && text[index] != '"'
                  index += 1
                end

                if index >= text.size
                  raise ManifestError.new("unterminated HLS attribute: #{text}")
                end

                result = text[value_start, index - value_start]
                index += 1
                result
              else
                value_start = index
                while index < text.size && text[index] != ','
                  index += 1
                end
                text[value_start, index - value_start].strip
              end

      attributes[key.upcase] = value unless key.empty?
    end

    attributes
  end

  private def parse_master(lines : Array(String), base_url : URI) : MultivariantPlaylist
    variants = [] of Variant
    pending : Hash(String, String)? = nil

    lines.each do |line|
      if line.starts_with?(STREAM_INF)
        pending = parse_attributes(line[STREAM_INF.size..])
        next
      end

      next if line.starts_with?('#')

      if attributes = pending
        variants << build_variant(attributes, line, base_url)
        pending = nil
      end
    end

    raise ManifestError.new("HLS master playlist has a dangling stream") if pending
    raise ManifestError.new("HLS master playlist has no variants") if variants.empty?

    MultivariantPlaylist.new(variants)
  end

  private def build_variant(
    attributes : Hash(String, String),
    uri_text : String,
    base_url : URI,
  ) : Variant
    width = nil
    height = nil

    if resolution = attributes["RESOLUTION"]?
      if match = /\A(\d+)x(\d+)\z/.match(resolution)
        width = match[1].to_i?
        height = match[2].to_i?
      end
    end

    Variant.new(
      url: resolve(uri_text, base_url),
      bandwidth: parse_i64(attributes["BANDWIDTH"]?),
      average_bandwidth: parse_i64(attributes["AVERAGE-BANDWIDTH"]?),
      width: width,
      height: height,
      codecs: attributes["CODECS"]?,
      audio_group: attributes["AUDIO"]?,
      subtitle_group: attributes["SUBTITLES"]?,
    )
  end

  private def parse_media(lines : Array(String), base_url : URI) : MediaPlaylist
    segments = [] of Segment
    map_url : URI? = nil
    map_byte_range : ByteRange? = nil
    encrypted = false
    ended = false
    duration = 0.0
    pending_duration = 0.0
    pending_title : String? = nil
    pending_range : ByteRange? = nil

    lines.each do |line|
      case
      when line.starts_with?(EXTINF)
        pending_duration, pending_title = parse_extinf(line[EXTINF.size..])
      when line.starts_with?(KEY)
        attributes = parse_attributes(line[KEY.size..])
        method = attributes["METHOD"]?
        encrypted = true unless method.nil? || method == "NONE"
      when line.starts_with?(MAP)
        attributes = parse_attributes(line[MAP.size..])
        uri = attributes["URI"]?
        raise ManifestError.new("HLS map section is missing a URI") unless uri

        map_url = resolve(uri, base_url)
        if range = attributes["BYTERANGE"]?
          map_byte_range = parse_byte_range(range)
        end
      when line.starts_with?(BYTERANGE)
        pending_range = parse_byte_range(line[BYTERANGE.size..])
      when line.starts_with?(ENDLIST)
        ended = true
      when line.starts_with?('#')
        next
      else
        segments << Segment.new(
          url: resolve(line, base_url),
          duration: pending_duration,
          title: pending_title,
          byte_range: pending_range,
        )
        duration += pending_duration
        pending_duration = 0.0
        pending_title = nil
        pending_range = nil
      end
    end

    raise ManifestError.new("HLS media playlist has no segments") if segments.empty?

    MediaPlaylist.new(
      segments: segments,
      duration_seconds: duration,
      ended: ended,
      encrypted: encrypted,
      map_url: map_url,
      map_byte_range: map_byte_range,
    )
  end

  private def parse_extinf(text : String) : Tuple(Float64, String?)
    duration_text, comma, title = text.partition(',')
    duration = duration_text.to_f?
    unless duration && duration.finite? && duration >= 0
      raise ManifestError.new("invalid HLS segment duration: #{duration_text}")
    end

    parsed_title = comma.empty? || title.empty? ? nil : title
    {duration, parsed_title}
  end

  private def parse_byte_range(value : String) : ByteRange
    length_text, separator, offset_text = value.strip.partition('@')
    length = length_text.to_i64?
    raise ManifestError.new("invalid HLS byte range: #{value}") unless length

    offset = nil
    unless separator.empty?
      offset = offset_text.to_i64?
      raise ManifestError.new("invalid HLS byte range offset: #{value}") unless offset
    end

    ByteRange.new(length, offset)
  end

  private def parse_i64(value : String?) : Int64?
    value.try(&.to_i64?)
  end

  private def resolve(value : String, base_url : URI) : URI
    uri = base_url.resolve(value)
    unless uri.scheme == "http" || uri.scheme == "https"
      raise ManifestError.new("unsupported HLS URI: #{value}")
    end
    uri
  rescue URI::Error
    raise ManifestError.new("invalid HLS URI: #{value}")
  end
end
