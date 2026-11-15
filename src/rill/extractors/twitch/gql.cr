require "json"

require "../../errors"
require "../../http_client"

module Rill::Extractors
  class TwitchGql
    DEFAULT_ENDPOINT = "https://gql.twitch.tv/gql"
    CLIENT_ID        = "ue6666qo983tsx6so1t0vnawi233wa"

    def initialize(@endpoint : String = DEFAULT_ENDPOINT)
    end

    def post(client : HTTPClient, body : String) : JSON::Any
      headers = HTTP::Headers.new
      headers["Client-ID"] = CLIENT_ID
      headers["Content-Type"] = "text/plain;charset=UTF-8"

      response = client.post(@endpoint, body, headers)
      JSON.parse(response.body)
    rescue JSON::ParseException
      raise MediaUnavailableError.new(@endpoint, "Twitch GraphQL response is not valid JSON")
    end
  end
end
