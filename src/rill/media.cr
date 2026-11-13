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
    )
    end

    def validate! : Nil
      if title.empty?
        raise InvalidExtractionError.new(webpage_url.to_s, "title is empty")
      end

      if formats.empty?
        raise InvalidExtractionError.new(webpage_url.to_s, "no formats")
      end

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
        json.field "formats" do
          json.array do
            formats.each(&.to_json(json))
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
    end
  end
end
