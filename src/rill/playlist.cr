require "json"
require "uri"

require "./errors"
require "./media"

module Rill
  class PlaylistEntry
    getter url : URI
    getter title : String?
    getter id : String?
    getter media : Media?
    getter error : String?

    def initialize(
      @url : URI,
      @title : String? = nil,
      @id : String? = nil,
      @media : Media? = nil,
      @error : String? = nil,
    )
    end

    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "url", url.to_s
        json.field "title", title
        json.field "id", id
        json.field "error", error
        json.field "media" do
          if item = media
            item.to_json(json)
          else
            json.null
          end
        end
      end
    end
  end

  class Playlist
    getter id : String?
    getter title : String
    getter description : String?
    getter webpage_url : URI
    getter extractor : String
    getter entries : Array(PlaylistEntry)

    def initialize(
      @title : String,
      @webpage_url : URI,
      @extractor : String,
      @entries : Array(PlaylistEntry),
      @id : String? = nil,
      @description : String? = nil,
    )
    end

    def validate! : Nil
      if title.empty?
        raise InvalidExtractionError.new(webpage_url.to_s, "playlist title is empty")
      end

      if entries.empty?
        raise InvalidExtractionError.new(webpage_url.to_s, "playlist has no entries")
      end

      entries.each do |entry|
        validate_entry!(entry)
      end
    end

    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "id", id
        json.field "title", title
        json.field "description", description
        json.field "webpage_url", webpage_url.to_s
        json.field "extractor", extractor
        json.field "entries" do
          json.array do
            entries.each(&.to_json(json))
          end
        end
      end
    end

    def to_pretty_json : String
      JSON.build(indent: 2) do |json|
        to_json(json)
      end
    end

    private def validate_entry!(entry : PlaylistEntry) : Nil
      scheme = entry.url.scheme
      if scheme != "http" && scheme != "https"
        raise InvalidExtractionError.new(webpage_url.to_s, "entry has a non-HTTP URL")
      end

      if entry.url.host.nil?
        raise InvalidExtractionError.new(webpage_url.to_s, "entry has no host")
      end

      if entry.media && entry.error
        raise InvalidExtractionError.new(webpage_url.to_s, "entry has both media and an error")
      end
    end
  end
end
