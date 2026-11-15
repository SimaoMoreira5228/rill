require "json"

require "../../errors"
require "../../http_client"
require "../../json_value"

module Rill::Extractors
  class YouTube < Extractor
    class PoTokenProvider
      def initialize(@endpoint : String)
      end

      def token(client : HTTPClient, binding : String) : String?
        body = JSON.build do |json|
          json.object do
            json.field "content_binding", binding
          end
        end

        headers = HTTP::Headers.new
        headers["Content-Type"] = "application/json"

        response = client.post(@endpoint, body, headers)
        payload = JSON.parse(response.body).as_h?
        token = JsonValue.string(payload.try(&.["po_token"]?))
        token if token && !token.empty?
      rescue Rill::Error | JSON::ParseException
        nil
      end
    end
  end
end
