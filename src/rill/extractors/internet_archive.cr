require "json"
require "uri"

require "../errors"
require "../extractor"
require "../format"
require "../media"

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

      title = scalar_string(metadata["title"]?) || identifier
      duration = parse_seconds(scalar_string(metadata["length"]?))
      duration ||= formats.compact_map(&.duration_seconds).first?

      Media.new(
        id: scalar_string(metadata["identifier"]?) || identifier,
        title: title,
        description: scalar_string(metadata["description"]?),
        webpage_url: url,
        uploader: scalar_string(metadata["creator"]?) || scalar_string(metadata["uploader"]?),
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

        label = scalar_string(file_hash["format"]?)
        format = Format.new(
          format_id: file_name,
          url: download_url(identifier, file_name),
          kind: kind_for(extension),
          container: extension,
          width: dimension(file_hash["width"]?),
          height: dimension(file_hash["height"]?),
          filesize: int_value(file_hash["size"]?),
          duration_seconds: parse_seconds(scalar_string(file_hash["length"]?)),
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
      value = scalar_string(metadata["date"]?) || scalar_string(metadata["addeddate"]?)
      return nil unless value

      value.size >= 10 ? value[0, 10] : value
    end

    private def scalar_string(value : JSON::Any?) : String?
      return nil unless value

      if string = value.as_s?
        string
      elsif array = value.as_a?
        array.each do |item|
          item_string = item.as_s?
          return item_string if item_string
        end
        nil
      elsif integer = value.as_i64?
        integer.to_s
      else
        nil
      end
    end

    private def int_value(value : JSON::Any?) : Int64?
      return nil unless value

      parsed = if string = value.as_s?
                 string.to_i64?
               else
                 value.as_i64?
               end
      return nil unless parsed && parsed >= 0

      parsed
    end

    private def dimension(value : JSON::Any?) : Int32?
      parsed = int_value(value)
      return nil unless parsed && 0 < parsed <= 100_000

      parsed.to_i32
    end

    private def parse_seconds(value : String?) : Float64?
      return nil unless value

      text = value.strip
      return nil if text.empty?

      seconds = if text.includes?(':')
                  total = 0.0
                  text.split(':').each do |part|
                    number = part.to_f?
                    return nil unless number
                    total = total * 60 + number
                  end
                  total
                else
                  text.to_f?
                end

      return nil unless seconds && seconds.finite? && seconds >= 0

      seconds
    end
  end
end
