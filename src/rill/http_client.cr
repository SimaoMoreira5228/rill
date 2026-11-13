require "http/client"
require "uri"

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
      "Authorization", "Cookie", "Proxy-Authorization",
    }

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

    def initialize(@options : RequestOptions = RequestOptions.new)
      validate_options!
    end

    def get(url : String | URI, headers : HTTP::Headers? = nil) : Response
      follow_redirects(url, headers) do |current_url, request_headers|
        attempt_buffered(current_url, request_headers)
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
      headers = initial_headers(extra_headers)
      redirects = 0

      loop do
        response = request.call(current_url, headers)

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

    private def attempt_buffered(url : URI, headers : HTTP::Headers) : Response
      attempt = 0

      loop do
        attempt += 1

        begin
          response = perform_buffered(url, headers)
        rescue ex : NetworkError
          raise ex if attempt > @options.retries
          sleep(retry_wait(attempt))
          next
        end

        return response unless retryable?(response.status) && attempt <= @options.retries

        sleep(retry_wait(attempt))
      end
    end

    private def perform_buffered(url : URI, headers : HTTP::Headers) : Response
      body = IO::Memory.new
      status = HTTP::Status::OK
      response_headers = HTTP::Headers.new

      with_client(url) do |client|
        client.exec(build_request(url, headers)) do |response|
          status = response.status
          response_headers = response.headers

          if status.success?
            read_body(response, url, body, @options.max_response_bytes)
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

    private def build_request(url : URI, headers : HTTP::Headers) : HTTP::Request
      HTTP::Request.new("GET", url.request_target, headers)
    end

    private def build_client(url : URI) : HTTP::Client
      client = HTTP::Client.new(
        url.host.not_nil!,
        url.port,
        tls: url.scheme == "https",
      )
      client.connect_timeout = @options.connect_timeout
      client.read_timeout = @options.read_timeout
      client
    end

    private def initial_headers(extra : HTTP::Headers?) : HTTP::Headers
      headers = HTTP::Headers.new
      copy_headers(@options.headers, headers)

      if extra
        copy_headers(extra, headers)
      end

      headers["User-Agent"] ||= @options.user_agent
      headers["Accept"] ||= "*/*"

      unless @options.cookies.empty?
        headers["Cookie"] ||= cookie_header
      end

      headers
    end

    private def copy_headers(source : HTTP::Headers, destination : HTTP::Headers) : Nil
      source.each do |name, values|
        values.each do |value|
          destination.add(name, value)
        end
      end
    end

    private def cookie_header : String
      @options.cookies.map { |name, value| "#{name}=#{value}" }.join("; ")
    end

    private def redirected_headers(
      headers : HTTP::Headers,
      from : URI,
      to : URI,
    ) : HTTP::Headers
      return headers if same_origin?(from, to)

      copy = HTTP::Headers.new
      headers.each do |name, values|
        next if SENSITIVE_HEADERS.includes?(name)

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
      @options.retry_delay * (1 << (attempt - 1))
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
