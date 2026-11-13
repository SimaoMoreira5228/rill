require "uri"

require "./errors"
require "./extractor"
require "./extractors/direct_media"
require "./extractors/hls"
require "./extractors/internet_archive"
require "./extractors/m3u"
require "./extractors/media_ccc_de"
require "./extractors/peer_tube"
require "./http_client"
require "./playlist"
require "./request_options"

module Rill
  class ExtractorRegistry
    def self.default : self
      registry = new
      registry.register(Extractors::InternetArchive)
      registry.register(Extractors::MediaCccDe)
      registry.register(Extractors::PeerTube)
      registry.register(Extractors::Hls)
      registry.register(Extractors::M3u)
      registry.register(Extractors::DirectMedia)
      registry
    end

    def initialize
      @extractors = [] of Extractor.class
    end

    def register(extractor : Extractor.class) : Nil
      @extractors << extractor
    end

    def extractors : Array(Extractor.class)
      @extractors.dup
    end

    def extractor_for(url : String | URI) : Extractor.class | Nil
      uri = url.is_a?(URI) ? url : URI.parse(url)
      return nil unless uri.scheme == "http" || uri.scheme == "https"

      @extractors.find { |extractor| extractor.new.matches?(uri) }
    rescue URI::Error
      nil
    end

    def extract(url : String | URI, options : RequestOptions = RequestOptions.new) : Media | Playlist
      extract(url, HTTPClient.new(options))
    end

    def extract(url : String | URI, client : HTTPClient) : Media | Playlist
      uri = parse_url(url)
      extractor = extractor_for(uri)
      unless extractor
        raise UnsupportedUrlError.new(uri.to_s)
      end

      result = extractor.new.extract(uri, client)
      case result
      when Media
        result.validate!
      when Playlist
        result.validate!
      end
      result
    end

    private def parse_url(url : String | URI) : URI
      uri = url.is_a?(URI) ? url : URI.parse(url)
      unless uri.scheme == "http" || uri.scheme == "https"
        raise UnsupportedUrlError.new(uri.to_s)
      end
      uri
    rescue URI::Error
      raise UnsupportedUrlError.new(url.to_s)
    end
  end
end
