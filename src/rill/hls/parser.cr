require "uri"

require "../errors"
require "./playlist"

module Rill::Hls::Parser
  extend self

  STREAM_INF             = "#EXT-X-STREAM-INF:"
  MEDIA                  = "#EXT-X-MEDIA:"
  EXTINF                 = "#EXTINF:"
  KEY                    = "#EXT-X-KEY:"
  MAP                    = "#EXT-X-MAP:"
  BYTERANGE              = "#EXT-X-BYTERANGE:"
  ENDLIST                = "#EXT-X-ENDLIST"
  TARGETDURATION         = "#EXT-X-TARGETDURATION:"
  MEDIA_SEQUENCE         = "#EXT-X-MEDIA-SEQUENCE:"
  DISCONTINUITY_SEQUENCE = "#EXT-X-DISCONTINUITY-SEQUENCE:"
  DISCONTINUITY          = "#EXT-X-DISCONTINUITY"

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
    renditions = [] of Rendition
    pending : Hash(String, String)? = nil

    lines.each do |line|
      if line.starts_with?(STREAM_INF)
        pending = parse_attributes(line[STREAM_INF.size..])
        next
      end

      if line.starts_with?(MEDIA)
        renditions << build_rendition(parse_attributes(line[MEDIA.size..]), base_url)
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

    MultivariantPlaylist.new(variants, renditions)
  end

  private def build_rendition(
    attributes : Hash(String, String),
    base_url : URI,
  ) : Rendition
    type = attributes["TYPE"]?
    raise ManifestError.new("HLS media rendition is missing a type") unless type

    uri = attributes["URI"]?

    Rendition.new(
      type: type.upcase,
      group_id: attributes["GROUP-ID"]?,
      name: attributes["NAME"]?,
      language: attributes["LANGUAGE"]?,
      url: uri ? resolve(uri, base_url) : nil,
      default: attributes["DEFAULT"]? == "YES",
      autoselect: attributes["AUTOSELECT"]? == "YES",
    )
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
    current_key : Key? = nil
    ended = false
    duration = 0.0
    pending_duration = 0.0
    pending_title : String? = nil
    pending_range : ByteRange? = nil
    pending_discontinuity = false
    target_duration : Float64? = nil
    media_sequence = 0_i64
    discontinuity_sequence = 0_i64

    lines.each do |line|
      case
      when line.starts_with?(EXTINF)
        pending_duration, pending_title = parse_extinf(line[EXTINF.size..])
      when line.starts_with?(KEY)
        current_key = parse_key(parse_attributes(line[KEY.size..]), base_url)
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
      when line.starts_with?(TARGETDURATION)
        target_duration = parse_target_duration(line[TARGETDURATION.size..])
      when line.starts_with?(MEDIA_SEQUENCE)
        media_sequence = parse_sequence(line[MEDIA_SEQUENCE.size..], "media sequence")
      when line.starts_with?(DISCONTINUITY_SEQUENCE)
        discontinuity_sequence = parse_sequence(line[DISCONTINUITY_SEQUENCE.size..], "discontinuity sequence")
      when line.starts_with?(DISCONTINUITY)
        pending_discontinuity = true
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
          key: current_key,
          discontinuity: pending_discontinuity,
        )
        duration += pending_duration
        pending_duration = 0.0
        pending_title = nil
        pending_range = nil
        pending_discontinuity = false
      end
    end

    raise ManifestError.new("HLS media playlist has no segments") if segments.empty? && ended

    MediaPlaylist.new(
      segments: segments,
      duration_seconds: duration,
      ended: ended,
      map_url: map_url,
      map_byte_range: map_byte_range,
      target_duration: target_duration,
      media_sequence: media_sequence,
      discontinuity_sequence: discontinuity_sequence,
    )
  end

  private def parse_key(
    attributes : Hash(String, String),
    base_url : URI,
  ) : Key?
    method = attributes["METHOD"]?
    return nil if method.nil? || method == "NONE"

    uri = attributes["URI"]?
    iv = attributes["IV"]?.try { |value| parse_iv(value) }

    Key.new(
      method: method.upcase,
      url: uri ? resolve(uri, base_url) : nil,
      iv: iv,
      key_format: attributes["KEYFORMAT"]? || "identity",
    )
  end

  private def parse_iv(value : String) : Bytes
    hex = value.starts_with?("0x") || value.starts_with?("0X") ? value[2..] : value
    number = hex.size == 32 ? hex.to_u128?(16) : nil
    unless number
      raise ManifestError.new("invalid HLS key IV: #{value}")
    end

    bytes = Bytes.new(16)
    16.times do |index|
      bytes[index] = ((number >> (8 * (15 - index))) & 0xff).to_u8
    end
    bytes
  end

  private def parse_target_duration(value : String) : Float64
    duration = value.strip.to_f?
    unless duration && duration.finite? && duration > 0
      raise ManifestError.new("invalid HLS target duration: #{value}")
    end

    duration
  end

  private def parse_sequence(value : String, label : String) : Int64
    sequence = value.strip.to_i64?
    unless sequence && sequence >= 0
      raise ManifestError.new("invalid HLS #{label}: #{value}")
    end

    sequence
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
