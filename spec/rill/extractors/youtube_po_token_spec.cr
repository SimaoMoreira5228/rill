require "../../spec_helper"

private def po_player_payload : String
  JSON.build do |json|
    json.object do
      json.field "playabilityStatus" do
        json.object do
          json.field "status", "OK"
        end
      end
      json.field "videoDetails" do
        json.object do
          json.field "videoId", "dQw4w9WgXcQ"
          json.field "title", "PO token test"
          json.field "author", "Test"
          json.field "lengthSeconds", "60"
        end
      end
      json.field "streamingData" do
        json.object do
          json.field "formats" do
            json.array do
              json.object do
                json.field "itag", 18
                json.field "mimeType", %(video/mp4; codecs="avc1.42001E, mp4a.40.2")
                json.field "url", "https://example.com/video.mp4"
                json.field "width", 640
                json.field "height", 360
                json.field "audioChannels", 2
                json.field "contentLength", "1000"
                json.field "bitrate", 500_000
              end
            end
          end
        end
      end
    end
  end
end

describe Rill::Extractors::YouTube do
  it "fetches visitor data when the watch page has none" do
    server = TestHTTPServer.new
    bindings = [] of String

    server.on("/watch") do |_, response|
      response.print(%(<script>"INNERTUBE_API_KEY":"test-key"</script>))
    end
    server.on("/youtubei/v1/visitor_id") do |_, response|
      response.print(%({"responseContext":{"visitorData":"fallback123"}}))
    end
    server.on("/youtubei/v1/player") do |request, response|
      body = request.body.try(&.gets_to_end) || ""
      if body.includes?(%("clientName":"WEB"))
        response.print(po_player_payload)
      else
        response.print(%({"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Sign in"}}))
      end
    end
    server.on("/pot") do |request, response|
      body = request.body.try(&.gets_to_end) || ""
      binding = JSON.parse(body)["content_binding"].as_s
      bindings << binding
      response.print(%({"po_token":"token-for-#{binding}"}))
    end
    server.start

    begin
      options = Rill::RequestOptions.new
      options.po_token_provider = "#{server.url}/pot"

      extractor = Rill::Extractors::YouTube.new(server.url)
      media = extractor.extract(
        URI.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
        Rill::HTTPClient.new(options),
      ).as(Rill::Media)

      bindings.should eq(["fallback123", "dQw4w9WgXcQ"])
      media.formats.first.url.query.not_nil!.should contain("pot=token-for-dQw4w9WgXcQ")
    ensure
      server.close
    end
  end

  it "uses a PO token provider for the web client" do
    server = TestHTTPServer.new
    player_bodies = [] of String
    bindings = [] of String
    provider_headers = [] of String?

    server.on("/watch") do |_, response|
      response.print(%(<script>"VISITOR_DATA":"visitor123","INNERTUBE_API_KEY":"test-key"</script>))
    end
    server.on("/youtubei/v1/player") do |request, response|
      body = request.body.try(&.gets_to_end) || ""
      player_bodies << body
      if body.includes?(%("clientName":"WEB"))
        response.print(po_player_payload)
      else
        response.print(%({"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Sign in"}}))
      end
    end
    server.on("/pot") do |request, response|
      body = request.body.try(&.gets_to_end) || ""
      binding = JSON.parse(body)["content_binding"].as_s
      bindings << binding
      provider_headers << request.headers["Content-Type"]?
      response.print(%({"po_token":"token-for-#{binding}"}))
    end
    server.start

    begin
      options = Rill::RequestOptions.new
      options.po_token_provider = "#{server.url}/pot"

      extractor = Rill::Extractors::YouTube.new(server.url)
      media = extractor.extract(
        URI.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
        Rill::HTTPClient.new(options),
      ).as(Rill::Media)
      media.validate!

      media.title.should eq("PO token test")
      media.formats.size.should eq(1)
      media.formats.first.url.query.not_nil!.should contain("pot=token-for-dQw4w9WgXcQ")

      bindings.should eq(["visitor123", "dQw4w9WgXcQ"])
      provider_headers.should eq(["application/json", "application/json"])

      web_body = player_bodies.find { |body| body.includes?(%("clientName":"WEB")) }.not_nil!
      web_body.should contain(%("serviceIntegrityDimensions":{"poToken":"token-for-visitor123"}))
    ensure
      server.close
    end
  end
end
