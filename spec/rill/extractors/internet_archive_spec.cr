require "../../spec_helper"

private def media_body(*parts : String) : String
  fixture("internet_archive", *parts)
end

describe Rill::Extractors::InternetArchive do
  it "matches item pages" do
    extractor = Rill::Extractors::InternetArchive.new

    extractor.matches?(URI.parse("https://archive.org/details/BigBuckBunny_124")).should be_true
    extractor.matches?(URI.parse("http://www.archive.org/details/foo/")).should be_true

    extractor.matches?(URI.parse("https://archive.org/metadata/foo")).should be_false
    extractor.matches?(URI.parse("https://example.com/details/foo")).should be_false
    extractor.matches?(URI.parse("ftp://archive.org/details/foo")).should be_false
  end

  it "extracts video item metadata and formats" do
    server = TestHTTPServer.new
    server.on("/metadata/BigBuckBunny_124") do |_, response|
      response.content_type = "application/json"
      response.print(media_body("big_buck_bunny.json"))
    end
    server.start

    begin
      extractor = Rill::Extractors::InternetArchive.new(server.url)
      media = extractor.extract(
        URI.parse("https://archive.org/details/BigBuckBunny_124"),
        Rill::HTTPClient.new,
      )
      media.validate!

      media.id.should eq("BigBuckBunny_124")
      media.title.should eq("Big Buck Bunny")
      media.uploader.should eq("jake@archive.org")
      media.upload_date.should eq("2011-07-01")
      media.duration_seconds.not_nil!.should be_close(596.46, 0.01)
      media.thumbnail_url.not_nil!.to_s.should eq("#{server.url}/services/img/BigBuckBunny_124")

      media.formats.size.should eq(3)

      mp4 = media.formats.find { |format| format.container == "mp4" }.not_nil!
      mp4.kind.should eq(Rill::FormatKind::Combined)
      mp4.note.should eq("h.264")
      mp4.filesize.should eq(61_878_609_i64)
      mp4.width.should eq(640)
      mp4.height.should eq(360)
      mp4.duration_seconds.not_nil!.should be_close(596.5, 0.01)
      mp4.url.to_s.should eq(
        "#{server.url}/download/BigBuckBunny_124/Content/big_buck_bunny_720p_surround.mp4",
      )
    ensure
      server.close
    end
  end

  it "extracts audio tracks and skips non-media files" do
    server = TestHTTPServer.new
    server.on("/metadata/test_audio_item") do |_, response|
      response.content_type = "application/json"
      response.print(media_body("test_audio_item.json"))
    end
    server.start

    begin
      extractor = Rill::Extractors::InternetArchive.new(server.url)
      media = extractor.extract(
        URI.parse("https://archive.org/details/test_audio_item"),
        Rill::HTTPClient.new,
      )
      media.validate!

      media.title.should eq("Test Audio Item")
      media.uploader.should eq("Test Artist")
      media.description.should eq("A fixture item for audio extraction.")
      media.duration_seconds.not_nil!.should be_close(215.32, 0.01)
      media.formats.size.should eq(3)
      media.formats.each do |format|
        format.kind.should eq(Rill::FormatKind::Audio)
      end

      short_track = media.formats.find { |format| format.format_id == "track02.mp3" }.not_nil!
      short_track.duration_seconds.not_nil!.should be_close(102.0, 0.01)
    ensure
      server.close
    end
  end

  it "reports dark items as unavailable" do
    server = TestHTTPServer.new
    server.on("/metadata/test_item") do |_, response|
      response.print(%({"is_dark": true}))
    end
    server.start

    begin
      extractor = Rill::Extractors::InternetArchive.new(server.url)
      expect_raises(Rill::MediaUnavailableError, /dark/) do
        extractor.extract(URI.parse("https://archive.org/details/test_item"), Rill::HTTPClient.new)
      end
    ensure
      server.close
    end
  end

  it "reports missing metadata as unavailable" do
    server = TestHTTPServer.new
    server.on("/metadata/test_item") { |_, response| response.print("{}") }
    server.start

    begin
      extractor = Rill::Extractors::InternetArchive.new(server.url)
      expect_raises(Rill::MediaUnavailableError, /metadata is missing/) do
        extractor.extract(URI.parse("https://archive.org/details/test_item"), Rill::HTTPClient.new)
      end
    ensure
      server.close
    end
  end

  it "reports items without media files as unavailable" do
    body = %({"metadata":{"identifier":"test_item","title":"Test"},"files":[{"name":"notes.txt","format":"Text"}]})
    server = TestHTTPServer.new
    server.on("/metadata/test_item") { |_, response| response.print(body) }
    server.start

    begin
      extractor = Rill::Extractors::InternetArchive.new(server.url)
      expect_raises(Rill::MediaUnavailableError, /no downloadable media/) do
        extractor.extract(URI.parse("https://archive.org/details/test_item"), Rill::HTTPClient.new)
      end
    ensure
      server.close
    end
  end

  it "reports malformed metadata as unavailable" do
    server = TestHTTPServer.new
    server.on("/metadata/test_item") { |_, response| response.print("not json") }
    server.start

    begin
      extractor = Rill::Extractors::InternetArchive.new(server.url)
      expect_raises(Rill::MediaUnavailableError, /not valid JSON/) do
        extractor.extract(URI.parse("https://archive.org/details/test_item"), Rill::HTTPClient.new)
      end
    ensure
      server.close
    end
  end

  it "falls back to the URL identifier as the title" do
    body = %({"metadata":{"identifier":"test_item"},"files":[{"name":"clip.mp4","format":"h.264"}]})
    server = TestHTTPServer.new
    server.on("/metadata/test_item") { |_, response| response.print(body) }
    server.start

    begin
      extractor = Rill::Extractors::InternetArchive.new(server.url)
      media = extractor.extract(
        URI.parse("https://archive.org/details/test_item"),
        Rill::HTTPClient.new,
      )

      media.title.should eq("test_item")
      media.id.should eq("test_item")
    ensure
      server.close
    end
  end
end
