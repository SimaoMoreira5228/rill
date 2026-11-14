require "json"
require "set"
require "uri"

require "./errors"
require "./format"

module Rill
  class Media
    getter id : String?
    getter title : String
    getter description : String?
    getter webpage_url : URI
    getter uploader : String?
    getter duration_seconds : Float64?
    getter thumbnail_url : URI?
    getter upload_date : String?
    getter extractor : String
    getter formats : Array(Format)
    getter warnings : Array(String)
    getter? is_live : Bool

    def initialize(
      @title : String,
      @webpage_url : URI,
      @extractor : String,
      @formats : Array(Format),
      @id : String? = nil,
      @description : String? = nil,
      @uploader : String? = nil,
      @duration_seconds : Float64? = nil,
      @thumbnail_url : URI? = nil,
      @upload_date : String? = nil,
      @warnings : Array(String) = [] of String,
      @is_live : Bool = false,
    )
    end

    def validate! : Nil
      if title.empty?
        raise InvalidExtractionError.new(webpage_url.to_s, "title is empty")
      end

      if formats.empty?
        raise InvalidExtractionError.new(webpage_url.to_s, "no formats")
      end

      validate_duration!(duration_seconds, "media duration")

      format_ids = Set(String).new
      formats.each do |format|
        validate_format!(format, format_ids)
      end
    end

    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "id", id
        json.field "title", title
        json.field "description", description
        json.field "webpage_url", webpage_url.to_s
        json.field "uploader", uploader
        json.field "duration_seconds", duration_seconds
        json.field "thumbnail_url", thumbnail_url.try(&.to_s)
        json.field "upload_date", upload_date
        json.field "extractor", extractor
        json.field "is_live", is_live?
        json.field "formats" do
          json.array do
            formats.each(&.to_json(json))
          end
        end
        json.field "warnings" do
          json.array do
            warnings.each { |warning| json.string(warning) }
          end
        end
      end
    end

    def to_pretty_json : String
      JSON.build(indent: 2) do |json|
        to_json(json)
      end
    end

    private def validate_format!(format : Format, format_ids : Set(String)) : Nil
      if format.url.host.nil?
        raise InvalidExtractionError.new(webpage_url.to_s, "format #{format.format_id} has no host")
      end

      scheme = format.url.scheme
      if scheme != "http" && scheme != "https"
        raise InvalidExtractionError.new(webpage_url.to_s, "format #{format.format_id} has a non-HTTP URL")
      end

      unless format_ids.add?(format.format_id)
        raise InvalidExtractionError.new(webpage_url.to_s, "duplicate format id #{format.format_id}")
      end

      validate_duration!(format.duration_seconds, "format #{format.format_id} duration")
      validate_positive!(format.width, "format #{format.format_id} width")
      validate_positive!(format.height, "format #{format.format_id} height")
      validate_non_negative!(format.filesize, "format #{format.format_id} filesize")

      if chunk_size = format.range_chunk_size
        if chunk_size <= 0
          raise InvalidExtractionError.new(webpage_url.to_s, "format #{format.format_id} chunk size is invalid")
        end
      end
      validate_non_negative!(format.video_bitrate, "format #{format.format_id} video bitrate")
      validate_non_negative!(format.audio_bitrate, "format #{format.format_id} audio bitrate")
      validate_non_negative!(format.bitrate, "format #{format.format_id} bitrate")

      if fps = format.fps
        unless fps.finite? && fps > 0
          raise InvalidExtractionError.new(webpage_url.to_s, "format #{format.format_id} has an invalid fps")
        end
      end
    end

    private def validate_duration!(value : Float64?, label : String) : Nil
      return unless value

      unless value.finite? && value >= 0
        raise InvalidExtractionError.new(webpage_url.to_s, "#{label} is invalid")
      end
    end

    private def validate_positive!(value : Int32?, label : String) : Nil
      return unless value

      if value <= 0
        raise InvalidExtractionError.new(webpage_url.to_s, "#{label} is invalid")
      end
    end

    private def validate_non_negative!(value : Int32?, label : String) : Nil
      return unless value

      if value < 0
        raise InvalidExtractionError.new(webpage_url.to_s, "#{label} is invalid")
      end
    end

    private def validate_non_negative!(value : Int64?, label : String) : Nil
      return unless value

      if value < 0
        raise InvalidExtractionError.new(webpage_url.to_s, "#{label} is invalid")
      end
    end
  end
end
