require "http/client"
require "uri"

require "./cookie_jar"
require "./errors"
require "./request_options"

module Rill
  class HTTPClient
    REDIRECT_STATUSES = {
      301, 302, 303, 307, 308,
    }

    RETRY_STATUSES = {
      408, 425, 429, 500, 502, 503, 504,
    }

    SENSITIVE_HEADERS = {
      "authorization", "cookie", "proxy-authorization", "host",
    }

    HEX = "0123456789ABCDEF"

    class Response
      getter status : HTTP::Status
      getter body : String
      getter headers : HTTP::Headers
      getter url : URI

      def initialize(
        @status : HTTP::Status,
        @body : String,
        @headers : HTTP::Headers,
        @url : URI,
      )
      end
    end

    @cookies : CookieJar
    @header_cookies : Hash(String, String)

    def initialize(@options : RequestOptions = RequestOptions.new)
      @cookies = CookieJar.new
      @header_cookies = parse_cookie_values(@options.headers.get?("Cookie"))
      validate_options!
    end

    getter cookies : CookieJar
    getter options : RequestOptions

    def get(url : String | URI, headers : HTTP::Headers? = nil) : Response
      follow_redirects(url, headers) do |current_url, request_headers|
        attempt_buffered(current_url, request_headers)
      end
    end

    def head(url : String | URI, headers : HTTP::Headers? = nil) : Response
      follow_redirects(url, headers) do |current_url, request_headers|
        attempt_buffered(current_url, request_headers, "HEAD")
      end
    end

    def post(url : String | URI, body : String, headers : HTTP::Headers? = nil) : Response
      request_headers = HTTP::Headers.new
      copy_headers(headers, request_headers) if headers
      request_headers["Content-Type"] ||= "application/json"

      follow_redirects(url, request_headers) do |current_url, headers_for_request|
        attempt_buffered(current_url, headers_for_request, "POST", body)
      end
    end

    def stream_to(
      url : String | URI,
      destination : IO,
      headers : HTTP::Headers? = nil,
      max_bytes : Int64? = nil,
      &before_body : HTTP::Status, HTTP::Headers, URI ->
    ) : Response
      follow_redirects(url, headers) do |current_url, request_headers|
        attempt_stream(current_url, request_headers, destination, max_bytes) do |status, response_headers, response_url|
          before_body.call(status, response_headers, response_url)
        end
      end
    end

    def stream_to(
      url : String | URI,
      destination : IO,
      headers : HTTP::Headers? = nil,
      max_bytes : Int64? = nil,
    ) : Response
      stream_to(url, destination, headers, max_bytes) { |_, _, _| }
    end

    private def follow_redirects(
      url : String | URI,
      extra_headers : HTTP::Headers?,
      &request : URI, HTTP::Headers -> Response
    ) : Response
      current_url = parse_url(url)
      origin_url = current_url
      headers = initial_headers(extra_headers)
      extra_cookies = parse_cookie_values(extra_headers.try(&.get?("Cookie")))
      redirects = 0

      loop do
        same_origin = same_origin?(origin_url, current_url)
        apply_cookies(headers, current_url, extra_cookies, same_origin)
        response = request.call(current_url, headers)
        @cookies.add(response.headers, current_url)

        if location = redirect_location(response)
          if redirects >= @options.max_redirects
            raise TooManyRedirectsError.new(current_url, @options.max_redirects)
          end

          target_url = current_url.resolve(location)
          validate_http_url!(target_url)
          headers = redirected_headers(headers, current_url, target_url)
          current_url = target_url
          redirects += 1
          next
        end

        unless response.status.success?
          raise HTTPError.new(current_url, response.status, response.body)
        end

        return response
      end
    end

    private def attempt_buffered(
      url : URI,
      headers : HTTP::Headers,
      method : String = "GET",
      body : String? = nil,
    ) : Response
      attempt = 0

      loop do
        attempt += 1

        begin
          response = perform_buffered(url, headers, method, body)
        rescue ex : NetworkError
          raise ex if attempt > @options.retries
          sleep(retry_wait(attempt))
          next
        end

        return response unless retryable?(response.status) && attempt <= @options.retries

        sleep(retry_wait(attempt))
      end
    end

    private def perform_buffered(
      url : URI,
      headers : HTTP::Headers,
      method : String,
      request_body : String?,
    ) : Response
      body = IO::Memory.new
      status = HTTP::Status::OK
      response_headers = HTTP::Headers.new

      with_client(url) do |client|
        client.exec(build_request(url, headers, method, request_body)) do |response|
          status = response.status
          response_headers = response.headers

          if status.success?
            read_body(response, url, body, @options.max_response_bytes) unless method == "HEAD"
          else
            body << read_error_body(response)
          end
        end
      end

      Response.new(status, body.to_s, response_headers, url)
    end

    private def attempt_stream(
      url : URI,
      headers : HTTP::Headers,
      destination : IO,
      max_bytes : Int64?,
      &before_body : HTTP::Status, HTTP::Headers, URI ->
    ) : Response
      status = HTTP::Status::OK
      response_headers = HTTP::Headers.new

      with_client(url) do |client|
        client.exec(build_request(url, headers)) do |response|
          status = response.status
          response_headers = response.headers

          unless status.success?
            return Response.new(status, read_error_body(response), response_headers, url)
          end

          before_body.call(status, response_headers, url)
          read_body(response, url, destination, max_bytes)
        end
      end

      Response.new(status, "", response_headers, url)
    end

    private def read_body(
      response : HTTP::Client::Response,
      url : URI,
      destination : IO,
      max_bytes : Int64?,
    ) : Nil
      content_length = response.headers["Content-Length"]?.try(&.to_i64?)
      if max_bytes && content_length && content_length > max_bytes
        raise ResponseTooLargeError.new(url, max_bytes)
      end

      io = response.body_io?
      return unless io

      buffer = Bytes.new(16 * 1024)
      total = 0_i64

      loop do
        read = io.read(buffer)
        break if read.zero?

        total += read
        if max_bytes && total > max_bytes
          raise ResponseTooLargeError.new(url, max_bytes)
        end

        destination.write(buffer[0, read])
      end

      if content_length && identity_encoded?(response) && total < content_length
        raise IncompleteResponseError.new(url, content_length, total)
      end
    end

    private def read_error_body(response : HTTP::Client::Response) : String
      io = response.body_io?
      return "" unless io

      body = IO::Memory.new
      buffer = Bytes.new(4 * 1024)
      remaining = 64 * 1024

      while remaining > 0
        read = io.read(buffer[0, Math.min(buffer.size, remaining)])
        break if read.zero?

        body.write(buffer[0, read])
        remaining -= read
      end

      body.to_s
    end

    private def with_client(url : URI, &)
      client = build_client(url)

      begin
        yield client
      rescue ex : IO::Error | Socket::Error
        raise NetworkError.new(url, ex)
      ensure
        client.close
      end
    end

    private def build_request(
      url : URI,
      headers : HTTP::Headers,
      method : String = "GET",
      body : String? = nil,
    ) : HTTP::Request
      request = HTTP::Request.new(method, request_target(url), headers)
      request.body = body if body
      request
    end

    private def request_target(url : URI) : String
      encode_target(url.request_target)
    end

    private def encode_target(value : String) : String
      String.build do |io|
        bytes = value.to_slice
        index = 0

        while index < bytes.size
          byte = bytes[index]

          if byte == 0x25_u8 && index + 2 < bytes.size &&
             hex_digit?(bytes[index + 1]) && hex_digit?(bytes[index + 2])
            io.write_byte(byte)
            io.write_byte(bytes[index + 1])
            io.write_byte(bytes[index + 2])
            index += 3
          elsif target_byte?(byte)
            io.write_byte(byte)
            index += 1
          else
            io << '%'
            io.write_byte(HEX.to_unsafe[byte >> 4])
            io.write_byte(HEX.to_unsafe[byte & 0x0f])
            index += 1
          end
        end
      end
    end

    private def hex_digit?(byte : UInt8) : Bool
      (0x30_u8 <= byte <= 0x39_u8) ||
        (0x41_u8 <= byte <= 0x46_u8) ||
        (0x61_u8 <= byte <= 0x66_u8)
    end

    private def target_byte?(byte : UInt8) : Bool
      (0x30_u8 <= byte <= 0x39_u8) ||
        (0x41_u8 <= byte <= 0x5a_u8) ||
        (0x61_u8 <= byte <= 0x7a_u8) ||
        "-._~!$&'()*+,;=:@/?".to_slice.includes?(byte)
    end

    private def identity_encoded?(response : HTTP::Client::Response) : Bool
      encoding = response.headers["Content-Encoding"]?
      encoding.nil? || encoding.downcase == "identity"
    end

    private def build_client(url : URI) : HTTP::Client
      client = HTTP::Client.new(
        url.host.not_nil!,
        url.port,
        tls: url.scheme == "https",
      )
      client.connect_timeout = @options.connect_timeout
      client.read_timeout = @options.read_timeout
      client.dns_timeout = @options.connect_timeout
      client
    end

    private def initial_headers(extra : HTTP::Headers?) : HTTP::Headers
      headers = HTTP::Headers.new
      copy_headers(@options.headers, headers)

      if extra
        copy_headers(extra, headers, replace: true)
      end

      headers["User-Agent"] ||= @options.user_agent
      headers["Accept"] ||= "*/*"

      headers
    end

    private def apply_cookies(
      headers : HTTP::Headers,
      url : URI,
      extra_cookies : Hash(String, String),
      include_explicit : Bool,
    ) : Nil
      headers.delete("Cookie")

      explicit = {} of String => String
      if include_explicit
        @header_cookies.each do |name, value|
          explicit[name] = value
        end
        extra_cookies.each do |name, value|
          explicit[name] = value
        end
        @options.cookies.each do |name, value|
          explicit[name] = value
        end
      end

      jar = @cookies.cookies_for(url).reject { |cookie| explicit.has_key?(cookie.name) }
      jar.sort_by! { |cookie| -(cookie.path || "/").size }

      values = jar.map(&.to_cookie_header)
      explicit.each do |name, value|
        values << "#{name}=#{value}"
      end

      return if values.empty?

      headers["Cookie"] = values.join("; ")
    end

    private def parse_cookie_values(values : Array(String)?) : Hash(String, String)
      cookies = {} of String => String
      return cookies unless values

      values.each do |header|
        header.split(';').each do |pair|
          name, separator, value = pair.partition('=')
          next if separator.empty? || name.strip.empty?

          cookies[name.strip] = value.strip
        end
      end

      cookies
    end

    private def copy_headers(
      source : HTTP::Headers,
      destination : HTTP::Headers,
      replace : Bool = false,
    ) : Nil
      source.each do |name, values|
        destination.delete(name) if replace
        values.each do |value|
          destination.add(name, value)
        end
      end
    end

    private def redirected_headers(
      headers : HTTP::Headers,
      from : URI,
      to : URI,
    ) : HTTP::Headers
      return headers if same_origin?(from, to)

      copy = HTTP::Headers.new
      headers.each do |name, values|
        next if SENSITIVE_HEADERS.includes?(name.downcase)

        values.each do |value|
          copy.add(name, value)
        end
      end
      copy
    end

    private def same_origin?(first : URI, second : URI) : Bool
      first.scheme == second.scheme &&
        first.host.try(&.downcase) == second.host.try(&.downcase) &&
        effective_port(first) == effective_port(second)
    end

    private def effective_port(url : URI) : Int32
      url.port || (url.scheme == "https" ? 443 : 80)
    end

    private def redirect_location(response : Response) : String?
      return nil unless REDIRECT_STATUSES.includes?(response.status.code)
      response.headers["Location"]?
    end

    private def retryable?(status : HTTP::Status) : Bool
      RETRY_STATUSES.includes?(status.code)
    end

    private def retry_wait(attempt : Int32) : Time::Span
      @options.retry_wait(attempt)
    end

    private def parse_url(url : String | URI) : URI
      uri = url.is_a?(URI) ? url : URI.parse(url)
      validate_http_url!(uri)
      uri
    rescue ex : URI::Error
      raise InvalidUrlError.new(url.to_s, ex.message || "malformed URL")
    end

    private def validate_http_url!(url : URI) : Nil
      unless url.scheme == "http" || url.scheme == "https"
        raise InvalidUrlError.new(url.to_s, "only HTTP and HTTPS are supported")
      end

      if url.host.nil? || url.host.not_nil!.empty?
        raise InvalidUrlError.new(url.to_s, "missing host")
      end
    end

    private def validate_options! : Nil
      if @options.retries < 0
        raise ArgumentError.new("retries must not be negative")
      end

      if @options.retries > 10
        raise ArgumentError.new("retries must not exceed 10")
      end

      if @options.max_redirects < 0
        raise ArgumentError.new("max_redirects must not be negative")
      end

      if @options.max_response_bytes <= 0
        raise ArgumentError.new("max_response_bytes must be positive")
      end

      if @options.connect_timeout <= Time::Span.zero
        raise ArgumentError.new("connect_timeout must be positive")
      end

      if @options.read_timeout <= Time::Span.zero
        raise ArgumentError.new("read_timeout must be positive")
      end

      if @options.user_agent.empty?
        raise ArgumentError.new("user_agent must not be empty")
      end
    end
  end
end
