require "../../spec_helper"

describe Rill::Extractors::M3u do
  extractor = Rill::Extractors::M3u.new

  it "matches .m3u URLs" do
    extractor.matches?(URI.parse("https://example.com/list.m3u")).should be_true
    extractor.matches?(URI.parse("https://example.com/LIST.M3U?x=1")).should be_true
    extractor.matches?(URI.parse("https://example.com/list.m3u8")).should be_false
    extractor.matches?(URI.parse("https://example.com/file.mp4")).should be_false
  end

  it "parses entries and titles in order" do
    server = TestHTTPServer.new
    server.on("/list.m3u") do |_, response|
      response.print(<<-M3U)
        #EXTM3U
        #EXTINF:123,First Song
        https://example.com/first.mp3
        #EXTINF:-1,
        second.mp3
        # a comment
        https://example.com/third.mp3
      M3U
    end
    server.start

    begin
      playlist = extractor.extract(URI.parse("#{server.url}/list.m3u"), Rill::HTTPClient.new)

      playlist.title.should eq("list")
      playlist.entries.size.should eq(3)
      playlist.entries[0].title.should eq("First Song")
      playlist.entries[0].url.to_s.should eq("https://example.com/first.mp3")
      playlist.entries[1].title.should be_nil
      playlist.entries[1].url.to_s.should eq("#{server.url}/second.mp3")
    ensure
      server.close
    end
  end

  it "skips non-HTTP entries" do
    server = TestHTTPServer.new
    server.on("/list.m3u") do |_, response|
      response.print("#EXTM3U\n/local/file.mp3\nhttps://example.com/ok.mp3\n")
    end
    server.start

    begin
      playlist = extractor.extract(URI.parse("#{server.url}/list.m3u"), Rill::HTTPClient.new)
      playlist.entries.size.should eq(2)
    ensure
      server.close
    end
  end

  it "reports empty playlists as unavailable" do
    server = TestHTTPServer.new
    server.on("/list.m3u") { |_, response| response.print("#EXTM3U\n") }
    server.start

    begin
      expect_raises(Rill::MediaUnavailableError, /no entries/) do
        extractor.extract(URI.parse("#{server.url}/list.m3u"), Rill::HTTPClient.new)
      end
    ensure
      server.close
    end
  end

  it "rejects HLS content" do
    server = TestHTTPServer.new
    server.on("/list.m3u") do |_, response|
      response.print("#EXTM3U\n#EXT-X-TARGETDURATION:10\n")
    end
    server.start

    begin
      expect_raises(Rill::UnsupportedManifestError, /m3u8/) do
        extractor.extract(URI.parse("#{server.url}/list.m3u"), Rill::HTTPClient.new)
      end
    ensure
      server.close
    end
  end
end
