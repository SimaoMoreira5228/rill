require "http/status"
require "uri"

module Rill
  class Error < Exception
  end

  class UnsupportedUrlError < Error
    getter url : String

    def initialize(@url : String)
      super("unsupported URL: #{@url}")
    end
  end

  class ExtractionError < Error
  end

  class MediaUnavailableError < ExtractionError
    getter url : String

    def initialize(@url : String, reason : String)
      super("media unavailable at #{@url}: #{reason}")
    end
  end

  class InvalidExtractionError < ExtractionError
    getter url : String

    def initialize(@url : String, reason : String)
      super("invalid extraction result for #{@url}: #{reason}")
    end
  end

  class HTTPError < Error
    getter url : URI
    getter status : HTTP::Status
    getter response_body : String

    def initialize(@url : URI, @status : HTTP::Status, @response_body : String)
      super("GET #{@url} returned #{@status.code} #{@status.description}")
    end
  end

  class ResponseTooLargeError < Error
    getter url : URI
    getter limit : Int64

    def initialize(@url : URI, @limit : Int64)
      super("response from #{@url} exceeded #{@limit} bytes")
    end
  end

  class TooManyRedirectsError < Error
    getter url : URI
    getter limit : Int32

    def initialize(@url : URI, @limit : Int32)
      super("request to #{@url} exceeded #{@limit} redirects")
    end
  end

  class NetworkError < Error
    getter url : URI

    def initialize(@url : URI, cause : Exception)
      super("request to #{@url} failed: #{cause.message}", cause)
    end
  end

  class InvalidUrlError < Error
    getter url : String

    def initialize(@url : String, reason : String)
      super("invalid URL #{@url}: #{reason}")
    end
  end

  class InvalidOptionsError < Error
    def initialize(reason : String)
      super("invalid request options: #{reason}")
    end
  end
end
