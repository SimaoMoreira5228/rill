require "uri"

module Rill::Hls
  struct ByteRange
    getter length : Int64
    getter offset : Int64?

    def initialize(@length : Int64, @offset : Int64? = nil)
    end
  end

  struct Variant
    getter url : URI
    getter bandwidth : Int64?
    getter average_bandwidth : Int64?
    getter width : Int32?
    getter height : Int32?
    getter codecs : String?
    getter audio_group : String?
    getter subtitle_group : String?

    def initialize(
      @url : URI,
      @bandwidth : Int64? = nil,
      @average_bandwidth : Int64? = nil,
      @width : Int32? = nil,
      @height : Int32? = nil,
      @codecs : String? = nil,
      @audio_group : String? = nil,
      @subtitle_group : String? = nil,
    )
    end
  end

  struct Segment
    getter url : URI
    getter duration : Float64
    getter title : String?
    getter byte_range : ByteRange?

    def initialize(
      @url : URI,
      @duration : Float64 = 0.0,
      @title : String? = nil,
      @byte_range : ByteRange? = nil,
    )
    end
  end

  struct Rendition
    getter type : String
    getter group_id : String?
    getter name : String?
    getter language : String?
    getter url : URI?
    getter? default : Bool
    getter? autoselect : Bool

    def initialize(
      @type : String,
      @group_id : String? = nil,
      @name : String? = nil,
      @language : String? = nil,
      @url : URI? = nil,
      @default : Bool = false,
      @autoselect : Bool = false,
    )
    end
  end

  struct MediaPlaylist
    getter segments : Array(Segment)
    getter map_url : URI?
    getter map_byte_range : ByteRange?
    getter duration_seconds : Float64
    getter ended : Bool
    getter encrypted : Bool

    def initialize(
      @segments : Array(Segment),
      @duration_seconds : Float64,
      @ended : Bool,
      @encrypted : Bool,
      @map_url : URI? = nil,
      @map_byte_range : ByteRange? = nil,
    )
    end
  end

  struct MultivariantPlaylist
    getter variants : Array(Variant)
    getter renditions : Array(Rendition)

    def initialize(
      @variants : Array(Variant),
      @renditions : Array(Rendition) = [] of Rendition,
    )
    end
  end
end
