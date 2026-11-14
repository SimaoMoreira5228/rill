require "json"
require "uri"

require "../errors"
require "../extractor"
require "../format"
require "../json_value"
require "../media"
require "../timestamp"

module Rill::Extractors
  class InternetArchive < Extractor
    BASE_URL     = "https://archive.org"
    DETAILS_PATH = %r{\A/details/([^/]+)/?\z}

    AUDIO_EXTENSIONS = %w(
      aac aif aiff ape flac m4a mp3 oga ogg opus shn wav wma
    )

    MEDIA_EXTENSIONS = {
      "3gp", "avi", "flv", "m2ts", "mkv", "mov", "mp4", "m4v",
      "mpg", "mpeg", "ogv", "ts", "webm", "wmv",
      "aac", "aif", "aiff", "ape", "flac", "m4a", "mp3", "oga",
      "ogg", "opus", "shn", "wav", "wma",
    }

    def initialize(@base_url : String = BASE_URL)
    end

    def name : String
      "internet_archive"
    end

    def matches?(url : URI) : Bool
      return false unless url.scheme == "http" || url.scheme == "https"
      return false unless archive_host?(url.host)

      !DETAILS_PATH.match(url.path).nil?
    end

    def extract(url : URI, client : HTTPClient) : Media
      identifier = identifier_for(url)
      unless identifier
        raise UnsupportedUrlError.new(url.to_s)
      end

      metadata_url = URI.parse("#{@base_url}/metadata/#{URI.encode_path_segment(identifier)}")
      response = client.get(metadata_url)
      payload = parse_payload(response.body, url)

      if payload["is_dark"]?.try(&.as_bool?)
        raise MediaUnavailableError.new(url.to_s, "item is dark")
      end

      metadata = payload["metadata"]?.try(&.as_h?)
      unless metadata
        raise MediaUnavailableError.new(url.to_s, "item metadata is missing")
      end

      formats = formats_from(payload["files"]?, identifier)
      if formats.empty?
        raise MediaUnavailableError.new(url.to_s, "item has no downloadable media")
      end

      title = JsonValue.string(metadata["title"]?) || identifier
      duration = Timestamp.clock_seconds(JsonValue.string(metadata["length"]?))
      duration ||= formats.compact_map(&.duration_seconds).first?

      Media.new(
        id: JsonValue.string(metadata["identifier"]?) || identifier,
        title: title,
        description: JsonValue.string(metadata["description"]?),
        webpage_url: url,
        uploader: JsonValue.string(metadata["creator"]?) || JsonValue.string(metadata["uploader"]?),
        duration_seconds: duration,
        thumbnail_url: thumbnail_url_for(identifier),
        upload_date: date_value(metadata),
        extractor: name,
        formats: formats,
      )
    end

    private def identifier_for(url : URI) : String?
      match = DETAILS_PATH.match(url.path)
      return nil unless match

      identifier = URI.decode(match[1])
      identifier.empty? ? nil : identifier
    end

    private def archive_host?(host : String?) : Bool
      case host.try(&.downcase)
      when "archive.org", "www.archive.org"
        true
      else
        false
      end
    end

    private def parse_payload(body : String, url : URI) : Hash(String, JSON::Any)
      payload = JSON.parse(body).as_h?
      unless payload
        raise MediaUnavailableError.new(url.to_s, "item metadata is not a JSON object")
      end

      payload
    rescue JSON::ParseException
      raise MediaUnavailableError.new(url.to_s, "item metadata is not valid JSON")
    end

    private def formats_from(files_value : JSON::Any?, identifier : String) : Array(Format)
      files = files_value.try(&.as_a?)
      return [] of Format unless files

      formats = [] of Format

      files.each do |file|
        file_hash = file.as_h?
        next unless file_hash

        file_name = file_hash["name"]?.try(&.as_s?)
        next unless file_name

        extension = File.extname(file_name).lchop('.').downcase
        next unless MEDIA_EXTENSIONS.includes?(extension)

        label = JsonValue.string(file_hash["format"]?)
        format = Format.new(
          format_id: file_name,
          url: download_url(identifier, file_name),
          kind: kind_for(extension),
          container: extension,
          width: JsonValue.dimension(file_hash["width"]?),
          height: JsonValue.dimension(file_hash["height"]?),
          filesize: int_value(file_hash["size"]?),
          duration_seconds: Timestamp.clock_seconds(JsonValue.string(file_hash["length"]?)),
          note: label,
        )
        formats << format
      end

      formats
    end

    private def download_url(identifier : String, file_name : String) : URI
      encoded_name = file_name.split('/').reject(&.empty?).map do |segment|
        URI.encode_path_segment(segment)
      end.join('/')

      encoded_identifier = URI.encode_path_segment(identifier)
      URI.parse("#{@base_url}/download/#{encoded_identifier}/#{encoded_name}")
    end

    private def thumbnail_url_for(identifier : String) : URI
      URI.parse("#{@base_url}/services/img/#{URI.encode_path_segment(identifier)}")
    end

    private def kind_for(extension : String) : FormatKind
      if AUDIO_EXTENSIONS.includes?(extension)
        FormatKind::Audio
      else
        FormatKind::Combined
      end
    end

    private def date_value(metadata : Hash(String, JSON::Any)) : String?
      value = JsonValue.string(metadata["date"]?) || JsonValue.string(metadata["addeddate"]?)
      return nil unless value

      value.size >= 10 ? value[0, 10] : value
    end

    private def int_value(value : JSON::Any?) : Int64?
      parsed = JsonValue.integer(value)
      return nil unless parsed && parsed >= 0

      parsed
    end
  end
end
