require "json"
require "uri"

require "./errors"
require "./format"
require "./http_client"
require "./media"

module Rill
  abstract class Extractor
    abstract def name : String

    abstract def matches?(url : URI) : Bool

    abstract def extract(url : URI, client : HTTPClient) : Media
  end
end
