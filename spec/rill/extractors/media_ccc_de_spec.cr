require "../../spec_helper"

private def ccc_event_body : String
  fixture("media_ccc_de", "event.json")
end

private def ccc_event_url : String
  "https://media.ccc.de/v/39c3-the-heartbreak-machine-nazis-in-the-echo-chamber"
end

describe Rill::Extractors::MediaCccDe do
  it "matches media.ccc.de event pages" do
    extractor = Rill::Extractors::MediaCccDe.new

    extractor.matches?(URI.parse(ccc_event_url)).should be_true
    extractor.matches?(URI.parse("https://www.media.ccc.de/v/some-talk/")).should be_true

    extractor.matches?(URI.parse("https://media.ccc.de/c/39c3")).should be_true
    extractor.matches?(URI.parse("https://media.ccc.de/conferences/39c3")).should be_true
    extractor.matches?(URI.parse("https://example.com/v/some-talk")).should be_false
    extractor.matches?(URI.parse("ftp://media.ccc.de/v/some-talk")).should be_false
  end

  it "extracts event metadata and recordings" do
    server = TestHTTPServer.new
    server.on("/public/events/39c3-the-heartbreak-machine-nazis-in-the-echo-chamber") do |_, response|
      response.content_type = "application/json"
      response.print(ccc_event_body)
    end
    server.start

    begin
      extractor = Rill::Extractors::MediaCccDe.new(server.url)
      media = extractor.extract(URI.parse(ccc_event_url), Rill::HTTPClient.new).as(Rill::Media)
      media.validate!

      media.id.should eq("958d3055-3929-56b8-b71c-25b3a64f1902")
      media.title.should eq("The Heartbreak Machine: Nazis in the Echo Chamber")
      media.uploader.should eq("Martha Root, Eva Hoffmann, Christian Fuchs")
      media.duration_seconds.not_nil!.should be_close(2691, 0.01)
      media.upload_date.should eq("2025-12-29")
      media.thumbnail_url.not_nil!.host.should eq("static.media.ccc.de")
      media.formats.size.should eq(11)

      video = media.formats.first
      video.kind.should eq(Rill::FormatKind::Combined)
      video.container.should eq("mp4")
      video.width.should eq(1920)
      video.height.should eq(1080)
      video.language.should eq("deu")
      video.note.should eq("video/mp4")
      video.url.to_s.should start_with("https://cdn.media.ccc.de/")

      audio = media.formats.find { |format| format.format_id.ends_with?(".mp3") }.not_nil!
      audio.kind.should eq(Rill::FormatKind::Audio)
      audio.container.should eq("mp3")
      audio.audio_codec.should eq("mp3")

      av1 = media.formats.find { |format| format.video_codec == "av01" }.not_nil!
      av1.container.should eq("webm")
    ensure
      server.close
    end
  end

  it "extracts conference events as a playlist" do
    server = TestHTTPServer.new
    server.on("/public/conferences/39c3") do |_, response|
      response.content_type = "application/json"
      response.print(fixture("media_ccc_de", "conference.json"))
    end
    server.start

    begin
      extractor = Rill::Extractors::MediaCccDe.new(server.url)
      playlist = extractor.extract(
        URI.parse("https://media.ccc.de/c/39c3"),
        Rill::HTTPClient.new,
      ).as(Rill::Playlist)
      playlist.validate!

      playlist.id.should eq("39c3")
      playlist.title.should eq("39C3: Power Cycles")
      playlist.entries.size.should eq(2)
      playlist.entries[0].id.should eq("event-1")
      playlist.entries[0].title.should eq("FAFO: How we stopped worrying")
      playlist.entries[0].url.to_s.should eq("https://media.ccc.de/v/39c3-sos-fafo")
      playlist.entries[1].url.to_s.should eq("https://media.ccc.de/v/39c3-infrastructure-review")
    ensure
      server.close
    end
  end

  it "reports missing events as unavailable" do
    server = TestHTTPServer.new
    server.on("/public/events/missing") do |_, response|
      response.status = :not_found
      response.print(%({"message":"not found"}))
    end
    server.start

    begin
      extractor = Rill::Extractors::MediaCccDe.new(server.url)
      expect_raises(Rill::MediaUnavailableError, /not found/) do
        extractor.extract(URI.parse("https://media.ccc.de/v/missing"), Rill::HTTPClient.new)
      end
    ensure
      server.close
    end
  end

  it "reports events without recordings as unavailable" do
    server = TestHTTPServer.new
    server.on("/public/events/empty") do |_, response|
      response.print(%({"title":"Empty","recordings":[]}))
    end
    server.start

    begin
      extractor = Rill::Extractors::MediaCccDe.new(server.url)
      expect_raises(Rill::MediaUnavailableError, /no downloadable recordings/) do
        extractor.extract(URI.parse("https://media.ccc.de/v/empty"), Rill::HTTPClient.new)
      end
    ensure
      server.close
    end
  end
end
