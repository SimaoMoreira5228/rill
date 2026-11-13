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
    extractor.matches?(URI.parse("https://www.youtube.com/playlist?list=abc")).should be_false
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
      )
      media.validate!

      media.id.should eq("dQw4w9WgXcQ")
      media.title.should eq("Rick Astley - Never Gonna Give You Up (Official Video) (4K Remaster)")
      media.uploader.should eq("Rick Astley")
      media.duration_seconds.not_nil!.should be_close(213.0, 0.01)
      media.formats.size.should eq(27)

      request = server.requests.first
      request.method.should eq("POST")
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

  it "reports live videos as unavailable" do
    server = TestHTTPServer.new
    server.on("/youtubei/v1/player") { |_, response| response.print(youtube_body("live.json")) }
    server.start

    begin
      extractor = Rill::Extractors::YouTube.new(server.url)
      expect_raises(Rill::MediaUnavailableError, /live videos/) do
        extractor.extract(URI.parse("https://www.youtube.com/watch?v=live1234567"), Rill::HTTPClient.new)
      end
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
