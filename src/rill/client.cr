require "path"
require "uri"

require "./cancellation"
require "./downloader"
require "./download_progress"
require "./extractor_registry"
require "./format"
require "./http_client"
require "./media"
require "./request_options"

module Rill
  class Client
    getter options : RequestOptions
    getter http : HTTPClient
    getter registry : ExtractorRegistry

    def initialize(
      @options : RequestOptions = RequestOptions.new,
      @registry : ExtractorRegistry = ExtractorRegistry.default,
    )
      @http = HTTPClient.new(@options)
    end

    def extract(url : String | URI) : Media
      @registry.extract(url, @http)
    end

    def download(
      source : Format | String | URI,
      target : String | Path,
      cancellation : Cancellation? = nil,
      on_progress : Proc(DownloadProgress, Nil)? = nil,
      resume : Bool = true,
      overwrite : Bool = false,
    ) : Path
      downloader = Downloader.new(
        @options,
        @http,
        resume: resume,
        overwrite: overwrite,
      )
      downloader.download(source, target, cancellation, on_progress)
    end
  end
end
