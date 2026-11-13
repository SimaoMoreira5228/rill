require "http/headers"

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
  end
end
