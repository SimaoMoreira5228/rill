require "http/params"
require "uri"

require "./gql"

module Rill::Extractors::Twitch
  module Usher
    extend self

    def url(base : String, path : String, token : TwitchGql::AccessToken) : URI
      params = HTTP::Params.new
      params["allow_source"] = "true"
      params["allow_audio_only"] = "true"
      params["allow_spectre"] = "true"
      params["p"] = Random.rand(1_000_000..10_000_000).to_s
      params["platform"] = "web"
      params["player"] = "twitchweb"
      params["supported_codecs"] = "av1,h265,h264"
      params["playlist_include_framerate"] = "true"
      params["sig"] = token.signature
      params["token"] = token.value

      URI.parse("#{base}/#{path}?#{params}")
    end
  end
end
