require "../../spec_helper"

private def youtube_body(name : String) : String
  fixture("youtube", name)
end

describe Rill::Extractors::YouTube do
  it "matches supported URL shapes" do
    extractor = Rill::Extractors::YouTube.new

    extractor.matches?(URI.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ")).should be_true
    extractor.matches?(URI.parse("https://youtu.be/dQw4w9WgXcQ?t=10")).should be_true
    extractor.matches?(URI.parse("https://www.youtube.com/shorts/dQw4w9WgXcQ")).should be_true
    extractor.matches?(URI.parse("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ")).should be_true
    extractor.matches?(URI.parse("https://music.youtube.com/watch?v=dQw4w9WgXcQ")).should be_true

    extractor.matches?(URI.parse("https://www.youtube.com/watch?v=short")).should be_false
    extractor.matches?(URI.parse("https://www.youtube.com/playlist?list=abc")).should be_true
    extractor.matches?(URI.parse("https://www.youtube.com/playlist")).should be_false
    extractor.matches?(URI.parse("https://example.com/playlist?list=abc")).should be_false
    extractor.matches?(URI.parse("https://example.com/watch?v=dQw4w9WgXcQ")).should be_false
  end

  it "extracts direct formats from the player response" do
    captured_body = nil.as(String?)
    server = TestHTTPServer.new
    server.on("/youtubei/v1/player") do |request, response|
      captured_body = request.body.try(&.gets_to_end)
      response.content_type = "application/json"
      response.print(youtube_body("player.json"))
    end
    server.start

    begin
      extractor = Rill::Extractors::YouTube.new(server.url)
      media = extractor.extract(
        URI.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
        Rill::HTTPClient.new,
      ).as(Rill::Media)
      media.validate!

      media.id.should eq("dQw4w9WgXcQ")
      media.title.should eq("Rick Astley - Never Gonna Give You Up (Official Video) (4K Remaster)")
      media.uploader.should eq("Rick Astley")
      media.duration_seconds.not_nil!.should be_close(213.0, 0.01)
      media.formats.size.should eq(27)

      request = server.requests.find { |item| item.method == "POST" }.not_nil!
      request.headers["X-YouTube-Client-Name"].should eq("101")
      captured_body.not_nil!.should contain("\"videoId\":\"dQw4w9WgXcQ\"")

      video = media.formats.find { |format| format.format_id == "137" }.not_nil!
      video.kind.should eq(Rill::FormatKind::Video)
      video.container.should eq("mp4")
      video.height.should eq(1080)
      video.video_codec.not_nil!.should start_with("avc1")
      video.filesize.not_nil!.should be > 0

      audio = media.formats.find { |format| format.format_id == "140" }.not_nil!
      audio.kind.should eq(Rill::FormatKind::Audio)
      audio.container.should eq("mp4")
      audio.audio_codec.not_nil!.should start_with("mp4a")
    ensure
      server.close
    end
  end

  it "uses watch page visitor data and the page API key" do
    captured_request : HTTP::Request? = nil
    server = TestHTTPServer.new
    server.on("/watch") do |_, response|
      response.headers.add("Set-Cookie", "VISITOR_INFO1_LIVE=visitor123; Path=/")
      response.print(
        %(<script>var ytcfg={"INNERTUBE_API_KEY":"test-key","VISITOR_DATA":"visitor123"};</script>),
      )
    end
    server.on("/youtubei/v1/player") do |request, response|
      captured_request = request
      response.print(youtube_body("player.json"))
    end
    server.start

    begin
      extractor = Rill::Extractors::YouTube.new(server.url)
      extractor.extract(
        URI.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
        Rill::HTTPClient.new,
      )

      request = captured_request.not_nil!
      request.resource.should contain("key=test-key")
      request.headers["X-Goog-Visitor-Id"].should eq("visitor123")
      request.headers["Cookie"]?.not_nil!.should contain("VISITOR_INFO1_LIVE=visitor123")
    ensure
      server.close
    end
  end

  it "falls back through clients when visionos is unplayable" do
    fallback = %({
      "playabilityStatus": {"status": "OK"},
      "videoDetails": {
        "videoId": "dQw4w9WgXcQ",
        "title": "Fallback",
        "author": "Example",
        "lengthSeconds": "10",
        "isLiveContent": false
      },
      "streamingData": {
        "adaptiveFormats": [
          {
            "itag": 18,
            "url": "https://example.com/video.mp4",
            "mimeType": "video/mp4",
            "width": 640,
            "height": 360,
            "audioChannels": 2,
            "bitrate": 500000,
            "contentLength": "1000"
          }
        ]
      }
    })

    clients = [] of String
    server = TestHTTPServer.new
    server.on("/watch") { |_, response| response.print(%({"VISITOR_DATA":"visitor123"})) }
    server.on("/youtubei/v1/player") do |request, response|
      client_name = request.headers["X-YouTube-Client-Name"]
      clients << client_name

      if client_name == "101" || client_name == "28" || client_name == "3"
        response.print(youtube_body("login_required.json"))
      else
        response.print(fallback)
      end
    end
    server.start

    begin
      extractor = Rill::Extractors::YouTube.new(server.url)
      media = extractor.extract(
        URI.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
        Rill::HTTPClient.new,
      ).as(Rill::Media)

      media.title.should eq("Fallback")
      media.formats.size.should eq(1)
      clients.should eq(["101", "28", "3", "7"])
    ensure
      server.close
    end
  end

  it "reports login-gated videos as unavailable" do
    server = TestHTTPServer.new
    server.on("/youtubei/v1/player") { |_, response| response.print(youtube_body("login_required.json")) }
    server.start

    begin
      extractor = Rill::Extractors::YouTube.new(server.url)
      expect_raises(Rill::MediaUnavailableError, /not a bot/) do
        extractor.extract(URI.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ"), Rill::HTTPClient.new)
      end
    ensure
      server.close
    end
  end

  it "extracts live HLS variants" do
    server = TestHTTPServer.new
    player = %({
      "playabilityStatus": {"status": "OK"},
      "videoDetails": {
        "videoId": "live1234567",
        "title": "Live stream",
        "author": "Example",
        "lengthSeconds": "0",
        "isLiveContent": true
      },
      "streamingData": {
        "hlsManifestUrl": "#{server.url}/live/master.m3u8"
      }
    })
    server.on("/youtubei/v1/player") { |_, response| response.print(player) }
    server.on("/live/master.m3u8") do |_, response|
      response.print(<<-M3U8)
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
        low/index.m3u8
      M3U8
    end
    server.on("/live/low/index.m3u8") do |_, response|
      response.print(<<-M3U8)
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXTINF:4,
        seg0.ts
      M3U8
    end
    server.start

    begin
      extractor = Rill::Extractors::YouTube.new(server.url)
      media = extractor.extract(
        URI.parse("https://www.youtube.com/watch?v=live1234567"),
        Rill::HTTPClient.new,
      ).as(Rill::Media)
      media.validate!

      media.is_live?.should be_true
      media.title.should eq("Live stream")
      media.formats.size.should eq(1)

      format = media.formats.first
      format.live?.should be_true
      format.container.should eq("ts")
      format.url.to_s.should eq("#{server.url}/live/low/index.m3u8")
    ensure
      server.close
    end
  end

  it "reports live videos without HLS as unavailable" do
    server = TestHTTPServer.new
    server.on("/youtubei/v1/player") { |_, response| response.print(youtube_body("live.json")) }
    server.start

    begin
      extractor = Rill::Extractors::YouTube.new(server.url)
      expect_raises(Rill::MediaUnavailableError, /live stream has no HLS manifest/) do
        extractor.extract(URI.parse("https://www.youtube.com/watch?v=live1234567"), Rill::HTTPClient.new)
      end
    ensure
      server.close
    end
  end

  it "sends one clientVersion for the Android VR client" do
    captured = nil.as(String?)
    server = TestHTTPServer.new
    server.on("/watch") { |_, response| response.print(%({"VISITOR_DATA":"visitor123"})) }
    server.on("/youtubei/v1/player") do |request, response|
      if request.headers["X-YouTube-Client-Name"] == "28"
        captured = request.body.try(&.gets_to_end)
        response.print(youtube_body("player.json"))
      else
        response.print(youtube_body("login_required.json"))
      end
    end
    server.start

    begin
      extractor = Rill::Extractors::YouTube.new(server.url)
      extractor.extract(
        URI.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
        Rill::HTTPClient.new,
      )

      captured.not_nil!.scan(/"clientVersion"/).size.should eq(1)
    ensure
      server.close
    end
  end

  it "uses direct formats for a finished livestream" do
    player = %({
      "playabilityStatus": {"status": "OK"},
      "videoDetails": {
        "videoId": "dQw4w9WgXcQ",
        "title": "Finished live",
        "author": "Example",
        "lengthSeconds": "10",
        "isLiveContent": true
      },
      "streamingData": {
        "formats": [
          {
            "itag": 18,
            "url": "https://example.com/video.mp4",
            "mimeType": "video/mp4",
            "width": 640,
            "height": 360,
            "audioChannels": 2,
            "bitrate": 500000,
            "contentLength": "1000"
          }
        ]
      }
    })

    server = TestHTTPServer.new
    server.on("/youtubei/v1/player") { |_, response| response.print(player) }
    server.start

    begin
      extractor = Rill::Extractors::YouTube.new(server.url)
      media = extractor.extract(
        URI.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
        Rill::HTTPClient.new,
      ).as(Rill::Media)

      media.is_live?.should be_false
      media.formats.size.should eq(1)
    ensure
      server.close
    end
  end

  it "reports ciphered-only responses clearly" do
    server = TestHTTPServer.new
    server.on("/youtubei/v1/player") { |_, response| response.print(youtube_body("cipher_only.json")) }
    server.start

    begin
      extractor = Rill::Extractors::YouTube.new(server.url)
      expect_raises(Rill::MediaUnavailableError, /JavaScript challenge/) do
        extractor.extract(URI.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ"), Rill::HTTPClient.new)
      end
    ensure
      server.close
    end
  end
end
