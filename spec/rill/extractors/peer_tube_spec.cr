require "../../spec_helper"

private def peer_tube_body : String
  fixture("peer_tube", "video.json")
end

describe Rill::Extractors::PeerTube do
  it "matches PeerTube video URLs" do
    extractor = Rill::Extractors::PeerTube.new

    extractor.matches?(URI.parse("https://example.com/w/abc123")).should be_true
    extractor.matches?(URI.parse("https://example.com/videos/watch/8c02afe6-47c2-4a21-9155-f165f9696f4c")).should be_true
    extractor.matches?(URI.parse("https://example.com/videos/embed/8c02afe6-47c2-4a21-9155-f165f9696f4c")).should be_true

    extractor.matches?(URI.parse("https://example.com/w/")).should be_false
    extractor.matches?(URI.parse("https://example.com/other/abc123")).should be_false
    extractor.matches?(URI.parse("ftp://example.com/w/abc123")).should be_false
  end

  it "extracts video metadata and files" do
    server = TestHTTPServer.new
    server.on("/api/v1/videos/ihLvvRhaSLhtvVZtRBVvFb") do |_, response|
      response.content_type = "application/json"
      response.print(peer_tube_body)
    end
    server.start

    begin
      extractor = Rill::Extractors::PeerTube.new(server.url)
      media = extractor.extract(
        URI.parse("https://example.com/w/ihLvvRhaSLhtvVZtRBVvFb"),
        Rill::HTTPClient.new,
      )
      media.validate!

      media.id.should eq("8c02afe6-47c2-4a21-9155-f165f9696f4c")
      media.title.should eq("Bobbypills: An Adult Animation studios journey to CG")
      media.uploader.should eq("Blender")
      media.duration_seconds.not_nil!.should be_close(2305.0, 0.01)
      media.upload_date.should eq("2026-11-13")
      media.thumbnail_url.not_nil!.to_s.should eq(
        "https://example.com/lazy-static/thumbnails/5a0b3f8f-28ee-47ae-a432-0869fa8cbdc8.jpg",
      )

      media.formats.size.should eq(2)

      video = media.formats.find { |format| format.format_id == "480p" }.not_nil!
      video.kind.should eq(Rill::FormatKind::Combined)
      video.container.should eq("mp4")
      video.height.should eq(480)
      video.fps.should eq(25.0)
      video.filesize.should eq(90_101_721_i64)
      video.bitrate.not_nil!.should be > 0
      video.language.should be_nil

      audio = media.formats.find { |format| format.format_id == "audio" }.not_nil!
      audio.kind.should eq(Rill::FormatKind::Audio)
      audio.height.should be_nil
    ensure
      server.close
    end
  end

  it "falls back to HLS when direct files are absent" do
    body = <<-JSON
      {
        "uuid": "hls-video",
        "name": "HLS only",
        "duration": 10,
        "files": [],
        "streamingPlaylists": [
          {"playlistUrl": "https://example.com/master.m3u8"}
        ]
      }
    JSON

    server = TestHTTPServer.new
    server.on("/api/v1/videos/hls-video") { |_, response| response.print(body) }
    server.start

    begin
      extractor = Rill::Extractors::PeerTube.new(server.url)
      media = extractor.extract(
        URI.parse("https://example.com/w/hls-video"),
        Rill::HTTPClient.new,
      )

      media.formats.size.should eq(1)
      media.formats.first.protocol.should eq(Rill::FormatProtocol::Hls)
      media.formats.first.url.to_s.should eq("https://example.com/master.m3u8")
    ensure
      server.close
    end
  end

  it "reports live videos as unavailable" do
    server = TestHTTPServer.new
    server.on("/api/v1/videos/live") do |_, response|
      response.print(%({"name":"Live","isLive":true,"files":[]}))
    end
    server.start

    begin
      extractor = Rill::Extractors::PeerTube.new(server.url)
      expect_raises(Rill::MediaUnavailableError, /live videos/) do
        extractor.extract(URI.parse("https://example.com/w/live"), Rill::HTTPClient.new)
      end
    ensure
      server.close
    end
  end

  it "reports private or missing videos as unavailable" do
    server = TestHTTPServer.new
    server.on("/api/v1/videos/private") do |_, response|
      response.status = :forbidden
      response.print("nope")
    end
    server.start

    begin
      extractor = Rill::Extractors::PeerTube.new(server.url)
      expect_raises(Rill::MediaUnavailableError, /private/) do
        extractor.extract(URI.parse("https://example.com/w/private"), Rill::HTTPClient.new)
      end
    ensure
      server.close
    end
  end

  it "reports videos without files as unavailable" do
    server = TestHTTPServer.new
    server.on("/api/v1/videos/empty") do |_, response|
      response.print(%({"name":"Empty","files":[],"streamingPlaylists":[]}))
    end
    server.start

    begin
      extractor = Rill::Extractors::PeerTube.new(server.url)
      expect_raises(Rill::MediaUnavailableError, /no downloadable files/) do
        extractor.extract(URI.parse("https://example.com/w/empty"), Rill::HTTPClient.new)
      end
    ensure
      server.close
    end
  end
end
