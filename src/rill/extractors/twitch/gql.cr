require "json"

require "../../errors"
require "../../http_client"
require "../../json_value"

module Rill::Extractors
  class TwitchGql
    DEFAULT_ENDPOINT = "https://gql.twitch.tv/gql"
    CLIENT_ID        = "ue6666qo983tsx6so1t0vnawi233wa"

    record AccessToken, value : String, signature : String

    def initialize(@endpoint : String = DEFAULT_ENDPOINT)
    end

    def playback_access_token(
      client : HTTPClient,
      query : String,
      field : String,
    ) : AccessToken
      body = JSON.build do |json|
        json.object do
          json.field "query", query
        end
      end

      response = post(client, body)
      data = response.as_h?.try(&.["data"]?).try(&.as_h?)
      token = data.try(&.[field]?).try(&.as_h?)

      value = JsonValue.string(token.try(&.["value"]?))
      signature = JsonValue.string(token.try(&.["signature"]?))
      unless value && signature
        raise MediaUnavailableError.new(@endpoint, "Twitch playback access token is unavailable")
      end

      AccessToken.new(value, signature)
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
