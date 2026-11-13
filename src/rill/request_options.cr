require "http/headers"
require "json"

require "./errors"
require "./version"

module Rill
  class RequestOptions
    DEFAULT_USER_AGENT         = "rill/#{VERSION}"
    DEFAULT_CONNECT_TIMEOUT    = 15.seconds
    DEFAULT_READ_TIMEOUT       = 30.seconds
    DEFAULT_MAX_REDIRECTS      = 10
    DEFAULT_RETRIES            =  2
    DEFAULT_RETRY_DELAY        = 1.second
    DEFAULT_MAX_RESPONSE_BYTES = 16_i64 * 1024 * 1024

    property user_agent : String = DEFAULT_USER_AGENT
    property headers : HTTP::Headers = HTTP::Headers.new
    property cookies : Hash(String, String) = {} of String => String
    property connect_timeout : Time::Span = DEFAULT_CONNECT_TIMEOUT
    property read_timeout : Time::Span = DEFAULT_READ_TIMEOUT
    property max_redirects : Int32 = DEFAULT_MAX_REDIRECTS
    property retries : Int32 = DEFAULT_RETRIES
    property retry_delay : Time::Span = DEFAULT_RETRY_DELAY
    property max_response_bytes : Int64 = DEFAULT_MAX_RESPONSE_BYTES

    def self.from_json(source : String) : RequestOptions
      object = begin
        JSON.parse(source)
      rescue JSON::ParseException
        raise InvalidOptionsError.new("options are not valid JSON")
      end.as_h?

      unless object
        raise InvalidOptionsError.new("options must be a JSON object")
      end

      options = new

      object.each do |key, value|
        case key
        when "user_agent"
          options.user_agent = string_option(key, value)
        when "headers"
          apply_headers(options, value)
        when "cookies"
          apply_cookies(options, value)
        when "connect_timeout_seconds"
          options.connect_timeout = seconds_option(key, value)
        when "read_timeout_seconds"
          options.read_timeout = seconds_option(key, value)
        when "retry_delay_seconds"
          options.retry_delay = seconds_option(key, value, allow_zero: true)
        when "max_redirects"
          options.max_redirects = int32_option(key, value)
        when "retries"
          options.retries = int32_option(key, value)
        when "max_response_bytes"
          options.max_response_bytes = integer_option(key, value)
        else
          raise InvalidOptionsError.new("unknown option #{key}")
        end
      end

      validate(options)
      options
    end

    private def self.apply_headers(options : RequestOptions, value : JSON::Any) : Nil
      headers = value.as_h?
      unless headers
        raise InvalidOptionsError.new("headers must be a JSON object")
      end

      headers.each do |name, header_value|
        if name.empty?
          raise InvalidOptionsError.new("header names must not be empty")
        end

        if text = header_value.as_s?
          options.headers.add(name, text)
        elsif values = header_value.as_a?
          values.each do |item|
            text = item.as_s?
            unless text
              raise InvalidOptionsError.new("header #{name} must be a string or an array of strings")
            end
            options.headers.add(name, text)
          end
        else
          raise InvalidOptionsError.new("header #{name} must be a string or an array of strings")
        end
      end
    end

    private def self.apply_cookies(options : RequestOptions, value : JSON::Any) : Nil
      cookies = value.as_h?
      unless cookies
        raise InvalidOptionsError.new("cookies must be a JSON object")
      end

      cookies.each do |name, cookie_value|
        text = cookie_value.as_s?
        unless text
          raise InvalidOptionsError.new("cookie #{name} must be a string")
        end

        if name.empty?
          raise InvalidOptionsError.new("cookie names must not be empty")
        end

        options.cookies[name] = text
      end
    end

    private def self.string_option(key : String, value : JSON::Any) : String
      value.as_s? || raise InvalidOptionsError.new("#{key} must be a string")
    end

    private def self.integer_option(key : String, value : JSON::Any) : Int64
      value.as_i64? || raise InvalidOptionsError.new("#{key} must be an integer")
    end

    private def self.int32_option(key : String, value : JSON::Any) : Int32
      integer = integer_option(key, value)
      unless Int32::MIN <= integer <= Int32::MAX
        raise InvalidOptionsError.new("#{key} is out of range")
      end
      integer.to_i32
    end

    private def self.seconds_option(
      key : String,
      value : JSON::Any,
      allow_zero : Bool = false,
    ) : Time::Span
      number = if float = value.as_f?
                 float
               elsif integer = value.as_i64?
                 integer.to_f
               else
                 raise InvalidOptionsError.new("#{key} must be a number")
               end

      if allow_zero ? number < 0 : number <= 0
        raise InvalidOptionsError.new("#{key} must be greater than zero")
      end

      number.seconds
    end

    private def self.validate(options : RequestOptions) : Nil
      if options.user_agent.empty?
        raise InvalidOptionsError.new("user_agent must not be empty")
      end

      if options.max_redirects < 0
        raise InvalidOptionsError.new("max_redirects must not be negative")
      end

      if options.retries < 0
        raise InvalidOptionsError.new("retries must not be negative")
      end

      if options.max_response_bytes <= 0
        raise InvalidOptionsError.new("max_response_bytes must be positive")
      end
    end
  end
end
