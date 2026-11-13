require "http/cookie"
require "uri"

module Rill
  class CookieJar
    private struct StoredCookie
      getter cookie : HTTP::Cookie
      getter host_only : Bool

      def initialize(@cookie : HTTP::Cookie, @host_only : Bool)
      end
    end

    def initialize
      @cookies = [] of StoredCookie
    end

    def add(headers : HTTP::Headers, url : URI) : Nil
      values = headers.get?("Set-Cookie")
      return if values.nil? || values.empty?

      values.each do |value|
        cookie = HTTP::Cookie::Parser.parse_set_cookie(value)
        next unless cookie
        next unless cookie.valid?

        host_only = cookie.domain.nil?
        cookie.domain = normalized_domain(cookie.domain) || url.host
        cookie.path ||= default_path(url.path)
        next if cookie.expired?

        store(StoredCookie.new(cookie, host_only))
      end
    end

    def cookies_for(url : URI) : Array(HTTP::Cookie)
      now = Time.utc
      @cookies.reject!(&.cookie.expired?(now))
      @cookies.select { |stored| matches?(stored, url) }.map(&.cookie)
    end

    private def store(stored : StoredCookie) : Nil
      cookie = stored.cookie

      @cookies.reject! do |existing|
        existing.cookie.name == cookie.name &&
          existing.cookie.domain.try(&.downcase) == cookie.domain.try(&.downcase) &&
          existing.cookie.path == cookie.path
      end

      @cookies << stored
    end

    private def matches?(stored : StoredCookie, url : URI) : Bool
      host = url.host.try(&.downcase)
      return false unless host

      cookie = stored.cookie
      return false unless domain_matches?(host, cookie.domain, stored.host_only)
      return false if cookie.secure && url.scheme != "https"

      path_match?(url.path, cookie.path || "/")
    end

    private def domain_matches?(host : String, domain : String?, host_only : Bool) : Bool
      return false unless domain

      normalized = normalized_domain(domain)
      return false unless normalized
      return host == normalized if host_only

      host == normalized || host.ends_with?(".#{normalized}")
    end

    private def normalized_domain(domain : String?) : String?
      return nil unless domain

      value = domain.strip.downcase.lchop('.')
      value.empty? ? nil : value
    end

    private def path_match?(request_path : String, cookie_path : String) : Bool
      return true if request_path == cookie_path
      return true if request_path.starts_with?(cookie_path) && cookie_path.ends_with?('/')

      request_path.starts_with?("#{cookie_path}/")
    end

    private def default_path(path : String) : String
      return "/" unless path.starts_with?('/')

      index = path.rindex('/')
      return "/" unless index && index > 0

      path[0, index]
    end
  end
end
