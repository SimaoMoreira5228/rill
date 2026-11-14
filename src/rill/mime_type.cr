module Rill
  struct MimeType
    getter type : String
    getter subtype : String
    getter codecs : String?

    def self.parse(value : String) : self
      parts = value.split(';').map(&.strip)
      media_type = parts.first?.try(&.downcase) || ""
      type, _, subtype = media_type.partition('/')

      codecs = parts.skip(1).compact_map do |part|
        name, separator, codec = part.partition('=')
        next unless separator == "=" && name.strip.downcase == "codecs"

        codec = codec.strip
        if codec.starts_with?('"') && codec.ends_with?('"')
          codec = codec[1..-2]
        end
        codec
      end.first?

      new(type, subtype, codecs)
    end

    def initialize(@type : String, @subtype : String, @codecs : String? = nil)
    end

    def audio? : Bool
      @type == "audio"
    end

    def video? : Bool
      @type == "video"
    end

    def empty? : Bool
      @type.empty? || @subtype.empty?
    end

    def container : String?
      return nil if @subtype.empty?

      @subtype == "mpeg" ? "mp3" : @subtype
    end

    def audio_codec : String?
      return @codecs if @codecs
      return nil if @subtype.empty?

      @subtype == "mpeg" ? "mp3" : @subtype
    end

    def codec_list : Array(String)
      @codecs.try(&.split(',').map(&.strip).reject(&.empty?)) || [] of String
    end
  end
end
