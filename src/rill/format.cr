require "json"
require "uri"

module Rill
  enum FormatKind
    Video
    Audio
    Combined
  end

  enum FormatProtocol
    Http
    Hls
    Dash
  end

  class Format
    getter format_id : String
    getter url : URI
    getter kind : FormatKind
    getter protocol : FormatProtocol
    getter container : String?
    getter bitrate : Int64?
    getter video_codec : String?
    getter audio_codec : String?
    getter width : Int32?
    getter height : Int32?
    getter fps : Float64?
    getter video_bitrate : Int32?
    getter audio_bitrate : Int32?
    getter filesize : Int64?
    getter range_chunk_size : Int64?
    getter duration_seconds : Float64?
    getter language : String?
    getter note : String?

    def initialize(
      @format_id : String,
      @url : URI,
      @kind : FormatKind = FormatKind::Combined,
      @protocol : FormatProtocol = FormatProtocol::Http,
      @container : String? = nil,
      @bitrate : Int64? = nil,
      @video_codec : String? = nil,
      @audio_codec : String? = nil,
      @width : Int32? = nil,
      @height : Int32? = nil,
      @fps : Float64? = nil,
      @video_bitrate : Int32? = nil,
      @audio_bitrate : Int32? = nil,
      @filesize : Int64? = nil,
      @range_chunk_size : Int64? = nil,
      @duration_seconds : Float64? = nil,
      @language : String? = nil,
      @note : String? = nil,
    )
    end

    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "format_id", format_id
        json.field "url", url.to_s
        json.field "kind", kind.to_s.downcase
        json.field "protocol", protocol.to_s.downcase
        json.field "container", container
        json.field "bitrate", bitrate
        json.field "video_codec", video_codec
        json.field "audio_codec", audio_codec
        json.field "width", width
        json.field "height", height
        json.field "fps", fps
        json.field "video_bitrate", video_bitrate
        json.field "audio_bitrate", audio_bitrate
        json.field "filesize", filesize
        json.field "range_chunk_size", range_chunk_size
        json.field "duration_seconds", duration_seconds
        json.field "language", language
        json.field "note", note
      end
    end
  end
end
