require "uri"

module Rill
  module HttpUrl
    extend self

    def absolute(value : String?) : URI?
      return nil unless value

      validate(URI.parse(value))
    rescue URI::Error
      nil
    end

    def resolve(base : URI, value : String) : URI?
      validate(base.resolve(value))
    rescue URI::Error
      nil
    end

    private def validate(uri : URI) : URI?
      return nil unless uri.scheme == "http" || uri.scheme == "https"
      return nil if uri.host.nil?

      uri
    end
  end
end
