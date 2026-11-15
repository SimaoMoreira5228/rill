require "http/params"
require "uri"

module Rill
  module Redaction
    extend self

    SENSITIVE_QUERY = {"pot", "sig", "lsig", "n", "signature", "token"}

    def url(value : URI) : String
      params = HTTP::Params.parse(value.query || "")
      return value.to_s if params.empty?

      keys = [] of String
      params.each { |key, _| keys << key }
      keys.each do |key|
        params[key] = "REDACTED" if SENSITIVE_QUERY.includes?(key.downcase)
      end

      updated = value.dup
      updated.query = params.to_s
      updated.to_s
    end

    def url(value : String) : String
      url(URI.parse(value))
    rescue URI::Error
      value
    end
  end
end
