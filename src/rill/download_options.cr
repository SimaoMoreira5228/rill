require "json"

require "./errors"
require "./format_selector"
require "./media_muxer"
require "./request_options"

module Rill
  class DownloadOptions
    getter request : RequestOptions
    getter format_id : String?
    getter preference : FormatPreference
    getter overwrite : Bool
    getter resume : Bool
    getter media_backend : MediaMuxer::Backend

    def initialize(
      @request : RequestOptions = RequestOptions.new,
      @format_id : String? = nil,
      @preference : FormatPreference = FormatPreference::AudioAndVideo,
      @overwrite : Bool = false,
      @resume : Bool = true,
      @media_backend : MediaMuxer::Backend = MediaMuxer.backend_from_environment,
    )
    end

    def self.from_json(source : String?) : DownloadOptions
      if source.nil? || source.empty?
        return new
      end

      object = JSON.parse(source).as_h?
      unless object
        raise InvalidOptionsError.new("download options must be a JSON object")
      end

      request = RequestOptions.new
      format_id = nil
      audio_only = false
      video_only = false
      overwrite = false
      resume = true
      media_backend = MediaMuxer.backend_from_environment

      object.each do |key, value|
        case key
        when "request"
          request = RequestOptions.from_json(value.to_json)
        when "format_id"
          format_id = value.as_s? || raise InvalidOptionsError.new("format_id must be a string")
        when "audio_only"
          audio_only = boolean_option(key, value)
        when "video_only"
          video_only = boolean_option(key, value)
        when "overwrite"
          overwrite = boolean_option(key, value)
        when "resume"
          resume = boolean_option(key, value)
        when "media_backend"
          name = value.as_s? || raise InvalidOptionsError.new("media_backend must be a string")
          media_backend = MediaMuxer.parse_backend(name) ||
                          raise InvalidOptionsError.new("unknown media_backend #{name}")
        else
          raise InvalidOptionsError.new("unknown download option #{key}")
        end
      end

      if audio_only && video_only
        raise InvalidOptionsError.new("audio_only and video_only cannot be combined")
      end

      if format_id && (audio_only || video_only)
        raise InvalidOptionsError.new("format_id cannot be combined with audio_only or video_only")
      end

      preference = if audio_only
                     FormatPreference::AudioOnly
                   elsif video_only
                     FormatPreference::VideoOnly
                   else
                     FormatPreference::AudioAndVideo
                   end

      new(request, format_id, preference, overwrite, resume, media_backend)
    rescue JSON::ParseException
      raise InvalidOptionsError.new("download options are not valid JSON")
    end

    private def self.boolean_option(key : String, value : JSON::Any) : Bool
      raw = value.raw
      return raw if raw.is_a?(Bool)

      raise InvalidOptionsError.new("#{key} must be a boolean")
    end
  end
end
