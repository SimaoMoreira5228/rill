require "../../spec_helper"

describe Rill::Extractors::Hls do
  extractor = Rill::Extractors::Hls.new

  it "matches m3u8 URLs" do
    extractor.matches?(URI.parse("https://example.com/master.m3u8")).should be_true
    extractor.matches?(URI.parse("https://example.com/PLAYLIST.M3U8?token=1")).should be_true
    extractor.matches?(URI.parse("https://example.com/video.mp4")).should be_false
    extractor.matches?(URI.parse("ftp://example.com/master.m3u8")).should be_false
  end

  it "extracts variants from a master playlist" do
    server = TestHTTPServer.new
    server.on("/master.m3u8") do |_, response|
      response.content_type = "application/vnd.apple.mpegurl"
      response.print(<<-M3U8)
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.4d401e,mp4a.40.2"
        low/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720,AUDIO="aud"
        high/index.m3u8
      M3U8
    end
    server.start

    begin
      media = extractor.extract(URI.parse("#{server.url}/master.m3u8"), Rill::HTTPClient.new)
      media.validate!

      media.title.should eq("master")
      media.formats.size.should eq(2)

      low = media.formats[0]
      low.url.to_s.should eq("#{server.url}/low/index.m3u8")
      low.protocol.should eq(Rill::FormatProtocol::Hls)
      low.kind.should eq(Rill::FormatKind::Combined)
      low.height.should eq(360)
      low.bitrate.should eq(800_000)
      low.note.should eq("avc1.4d401e,mp4a.40.2")

      high = media.formats[1]
      high.kind.should eq(Rill::FormatKind::Video)
      high.height.should eq(720)
    ensure
      server.close
    end
  end

  it "extracts a media playlist" do
    server = TestHTTPServer.new
    server.on("/index.m3u8") do |_, response|
      response.print(<<-M3U8)
        #EXTM3U
        #EXTINF:9.9,First
        seg0.ts
        #EXTINF:10,
        seg1.ts
        #EXT-X-ENDLIST
      M3U8
    end
    server.start

    begin
      media = extractor.extract(URI.parse("#{server.url}/index.m3u8"), Rill::HTTPClient.new)
      media.validate!

      media.duration_seconds.not_nil!.should be_close(19.9, 0.001)
      media.formats.size.should eq(1)

      format = media.formats.first
      format.protocol.should eq(Rill::FormatProtocol::Hls)
      format.container.should eq("ts")
      format.url.to_s.should eq("#{server.url}/index.m3u8")
      format.duration_seconds.not_nil!.should be_close(19.9, 0.001)
    ensure
      server.close
    end
  end
end
