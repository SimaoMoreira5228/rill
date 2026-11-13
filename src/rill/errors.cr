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

  class IncompleteResponseError < Error
    getter url : URI
    getter expected_bytes : Int64
    getter actual_bytes : Int64

    def initialize(@url : URI, @expected_bytes : Int64, @actual_bytes : Int64)
      super("response from #{@url} ended after #{@actual_bytes} of #{@expected_bytes} bytes")
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

  class ManifestError < Error
  end

  class UnsupportedManifestError < ManifestError
  end

  class CancelledError < Error
    def initialize
      super("operation cancelled")
    end
  end

  class DownloadError < Error
  end

  class DownloadWriteError < DownloadError
    getter path : String

    def initialize(@path : String, cause : Exception)
      super("failed to write #{@path}: #{cause.message}", cause)
    end
  end

  class FileExistsError < DownloadError
    getter path : String

    def initialize(@path : String)
      super("file already exists: #{@path}")
    end
  end

  class IncompleteDownloadError < DownloadError
    getter path : String
    getter expected_bytes : Int64
    getter actual_bytes : Int64

    def initialize(@path : String, @expected_bytes : Int64, @actual_bytes : Int64)
      super("incomplete download for #{@path}: expected #{@expected_bytes} bytes, got #{@actual_bytes}")
    end
  end

  class ResumeError < DownloadError
    getter path : String

    def initialize(@path : String, reason : String)
      super("cannot resume #{@path}: #{reason}")
    end
  end

  class InvalidOutputPathError < DownloadError
    def initialize(path : String, directory : String)
      super("refusing to write #{path} outside #{directory}")
    end
  end
end
