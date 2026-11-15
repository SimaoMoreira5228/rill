require "../../spec_helper"

private def odysee_api(
  server : TestHTTPServer,
  stream_url : String,
  resolve_fixture : String = "resolve.json",
) : Nil
  server.on("/api") do |request, response|
    body = request.body.try(&.gets_to_end) || ""
    response.headers["Content-Type"] = "application/json"
    if body.includes?(%("method":"resolve"))
      response.print(fixture("odysee", resolve_fixture))
    else
      response.print(fixture("odysee", "streaming.json").gsub("STREAM_URL", stream_url))
    end
  end
end

describe Rill::Extractors::Odysee do
  it "matches claim URLs and rejects channels" do
    extractor = Rill::Extractors::Odysee.new

    %w[
      https://odysee.com/@Mantega:1/First-day-LBRY:1
      https://www.odysee.com/@Mantega:1/First-day-LBRY:1
      https://lbry.tv/@Mantega:1/First-day-LBRY:1
      https://odysee.com/$/embed/@Mantega:1/First-day-LBRY:1
      https://odysee.com/$/download/@Mantega:1/First-day-LBRY:1
      https://odysee.com/First-day-LBRY:1
      https://odysee.com/First-day-LBRY%3A1
    ].each do |url|
      extractor.matches?(URI.parse(url)).should be_true
    end

    %w[
      https://odysee.com/@Mantega:1
      https://odysee.com/
      https://odysee.com/@Mantega:1/First-day-LBRY
      https://example.com/@Mantega:1/First-day-LBRY:1
      https://odysee.com.evil.com/@Mantega:1/First-day-LBRY:1
      ftp://odysee.com/@Mantega:1/First-day-LBRY:1
    ].each do |url|
      extractor.matches?(URI.parse(url)).should be_false
    end
  end

  it "extracts a claim with a direct media format" do
    server = TestHTTPServer.new
    odysee_api(server, "#{server.url}/stream.mp4")
    seen = [] of Tuple(String, String?)

    server.on("/stream.mp4") do |request, response|
      seen << {request.method, request.headers["Referer"]?}
      response.headers["Content-Type"] = "video/mp4"
      response.content_length = 94_027_711
    end
    server.start

    begin
      extractor = Rill::Extractors::Odysee.new("#{server.url}/api")
      media = extractor.extract(
        URI.parse("https://odysee.com/@Mantega:1/First-day-LBRY:1"),
        Rill::HTTPClient.new,
      )
      media.validate!

      media.id.should eq("17f983b61f53091fb8ea58a9c56804e4ff8cff4d")
      media.title.should eq("First day in LBRY? Start HERE!")
      media.description.should eq("A short introduction to LBRY.")
      media.uploader.should eq("LBRY/Odysee rats united!!!")
      media.duration_seconds.not_nil!.should eq(346.0)
      media.upload_date.should eq("2020-07-25")
      media.thumbnail_url.not_nil!.to_s.should eq("https://spee.ch/7/67f2d809c263288c.png")
      media.is_live?.should be_false

      format = media.formats.first
      format.protocol.should eq(Rill::FormatProtocol::Http)
      format.kind.should eq(Rill::FormatKind::Combined)
      format.container.should eq("mp4")
      format.width.should eq(1280)
      format.height.should eq(720)
      format.filesize.should eq(94_027_711)
      format.headers["Referer"].should eq("https://odysee.com/")

      seen.should eq([{"HEAD", "https://odysee.com/"}])
    ensure
      server.close
    end
  end

  it "follows a repost to the original stream" do
    server = TestHTTPServer.new
    get_body = nil

    server.on("/api") do |request, response|
      body = request.body.try(&.gets_to_end) || ""
      get_body = body if body.includes?(%("method":"get"))
      payload = if body.includes?(%("method":"resolve"))
                  fixture("odysee", "resolve_repost.json")
                else
                  fixture("odysee", "streaming.json").gsub("STREAM_URL", "#{server.url}/stream.mp4")
                end
      response.headers["Content-Type"] = "application/json"
      response.print(payload)
    end
    server.on("/stream.mp4") do |_, response|
      response.headers["Content-Type"] = "video/mp4"
    end
    server.start

    begin
      extractor = Rill::Extractors::Odysee.new("#{server.url}/api")
      media = extractor.extract(
        URI.parse("https://odysee.com/@Repost:1/copied:2"),
        Rill::HTTPClient.new,
      )

      media.id.should eq("17f983b61f53091fb8ea58a9c56804e4ff8cff4d")
      media.title.should eq("First day in LBRY? Start HERE!")
      media.uploader.should eq("LBRY/Odysee rats united!!!")
      get_body.not_nil!.should contain(%("uri":"lbry://@Mantega#1/First-day-LBRY#1"))
      get_body.not_nil!.should contain(%("claim_id":"17f983b61f53091fb8ea58a9c56804e4ff8cff4d"))
    ensure
      server.close
    end
  end

  it "resolves an HLS master playlist and follows the redirect" do
    server = TestHTTPServer.new
    odysee_api(server, "#{server.url}/stream")
    playlist_headers = [] of String?

    server.on("/stream") do |_, response|
      response.status = :found
      response.headers["Location"] = "/stream.m3u8"
    end
    server.on("/stream.m3u8") do |request, response|
      playlist_headers << request.headers["Referer"]?
      response.print(<<-M3U8)
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.4d401e,mp4a.40.2"
        v0.m3u8
      M3U8
    end
    server.on("/v0.m3u8") do |request, response|
      playlist_headers << request.headers["Referer"]?
      response.print("#EXTM3U\n#EXTINF:4,\nseg.ts\n#EXT-X-ENDLIST\n")
    end
    server.start

    begin
      extractor = Rill::Extractors::Odysee.new("#{server.url}/api")
      media = extractor.extract(
        URI.parse("https://odysee.com/@Mantega:1/First-day-LBRY:1"),
        Rill::HTTPClient.new,
      )

      format = media.formats.first
      format.protocol.should eq(Rill::FormatProtocol::Hls)
      format.kind.should eq(Rill::FormatKind::Combined)
      format.url.to_s.should eq("#{server.url}/v0.m3u8")
      format.headers["Referer"].should eq("https://odysee.com/")
      media.is_live?.should be_false

      playlist_headers.should eq([
        "https://odysee.com/",
        "https://odysee.com/",
        "https://odysee.com/",
      ])
    ensure
      server.close
    end
  end

  it "reports a claim error from the API" do
    server = TestHTTPServer.new
    odysee_api(server, "#{server.url}/stream.mp4", "resolve_missing.json")
    server.start

    begin
      extractor = Rill::Extractors::Odysee.new("#{server.url}/api")

      expect_raises(Rill::MediaUnavailableError, /claim not found/) do
        extractor.extract(
          URI.parse("https://odysee.com/@nope:1/nothing:1"),
          Rill::HTTPClient.new,
        )
      end
    ensure
      server.close
    end
  end

  it "reports a missing streaming URL" do
    server = TestHTTPServer.new
    server.on("/api") do |request, response|
      body = request.body.try(&.gets_to_end) || ""
      response.headers["Content-Type"] = "application/json"
      if body.includes?(%("method":"resolve"))
        response.print(fixture("odysee", "resolve.json"))
      else
        response.print(%({"jsonrpc":"","result":{},"id":0}))
      end
    end
    server.start

    begin
      extractor = Rill::Extractors::Odysee.new("#{server.url}/api")

      expect_raises(Rill::MediaUnavailableError, /streaming URL/) do
        extractor.extract(
          URI.parse("https://odysee.com/@Mantega:1/First-day-LBRY:1"),
          Rill::HTTPClient.new,
        )
      end
    ensure
      server.close
    end
  end
end
