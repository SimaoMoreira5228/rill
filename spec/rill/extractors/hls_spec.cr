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
      high.url.to_s.should eq("#{server.url}/high/index.m3u8")
      high.kind.should eq(Rill::FormatKind::Combined)
      high.height.should eq(720)
    ensure
      server.close
    end
  end

  it "extracts separate-audio variants" do
    server = TestHTTPServer.new
    server.on("/master.m3u8") do |_, response|
      response.print(<<-M3U8)
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI="audio/en.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720,AUDIO="aud",CODECS="avc1.4d401f"
        high/index.m3u8
      M3U8
    end
    server.on("/high/index.m3u8") do |_, response|
      response.print(<<-M3U8)
        #EXTM3U
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:4,
        seg0.m4s
        #EXT-X-ENDLIST
      M3U8
    end
    server.on("/audio/en.m3u8") do |_, response|
      response.print(<<-M3U8)
        #EXTM3U
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:4,
        seg0.m4s
        #EXT-X-ENDLIST
      M3U8
    end
    server.start

    begin
      media = extractor.extract(URI.parse("#{server.url}/master.m3u8"), Rill::HTTPClient.new)
      media.validate!

      media.formats.size.should eq(2)

      video = media.formats.find { |format| format.kind == Rill::FormatKind::Video }.not_nil!
      video.url.to_s.should eq("#{server.url}/high/index.m3u8")
      video.container.should eq("mp4")
      video.width.should eq(1280)
      video.height.should eq(720)

      audio = media.formats.find { |format| format.kind == Rill::FormatKind::Audio }.not_nil!
      audio.url.to_s.should eq("#{server.url}/audio/en.m3u8")
      audio.container.should eq("mp4")
      audio.language.should eq("en")
      audio.note.should eq("English")

      plan = Rill::FormatSelector.plan(media.formats).not_nil!
      plan.stream.format_id.should eq("hls-1")
      plan.audio.not_nil!.format_id.should eq("audio-1")
    ensure
      server.close
    end
  end

  it "selects the default audio rendition and warns about alternates" do
    server = TestHTTPServer.new
    server.on("/master.m3u8") do |_, response|
      response.print(<<-M3U8)
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI="audio/en.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="French",LANGUAGE="fr",DEFAULT=NO,AUTOSELECT=YES,URI="audio/fr.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720,AUDIO="aud"
        high/index.m3u8
      M3U8
    end
    server.on("/high/index.m3u8") do |_, response|
      response.print(<<-M3U8)
        #EXTM3U
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:4,
        seg0.m4s
        #EXT-X-ENDLIST
      M3U8
    end
    server.start

    begin
      media = extractor.extract(URI.parse("#{server.url}/master.m3u8"), Rill::HTTPClient.new)

      media.warnings.should contain("only default audio renditions are exposed")

      audio = media.formats.find { |format| format.kind == Rill::FormatKind::Audio }.not_nil!
      audio.url.to_s.should eq("#{server.url}/audio/en.m3u8")
      audio.language.should eq("en")
    ensure
      server.close
    end
  end

  it "rejects separate audio when the container cannot be detected" do
    server = TestHTTPServer.new
    server.on("/master.m3u8") do |_, response|
      response.print(<<-M3U8)
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",URI="audio/en.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720,AUDIO="aud"
        high/index.m3u8
      M3U8
    end
    server.on("/audio/en.m3u8") do |_, response|
      response.print(<<-M3U8)
        #EXTM3U
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:4,
        seg0.m4s
        #EXT-X-ENDLIST
      M3U8
    end
    server.start

    begin
      expect_raises(Rill::UnsupportedManifestError, /cannot determine HLS container/) do
        extractor.extract(URI.parse("#{server.url}/master.m3u8"), Rill::HTTPClient.new)
      end
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

  it "marks live master variants" do
    server = TestHTTPServer.new
    server.on("/master.m3u8") do |_, response|
      response.print(<<-M3U8)
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
        low/index.m3u8
      M3U8
    end
    server.on("/low/index.m3u8") do |_, response|
      response.print(<<-M3U8)
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXTINF:4,
        seg0.ts
      M3U8
    end
    server.start

    begin
      media = extractor.extract(URI.parse("#{server.url}/master.m3u8"), Rill::HTTPClient.new)
      media.validate!

      media.is_live?.should be_true
      media.formats.size.should eq(1)

      format = media.formats.first
      format.live?.should be_true
      format.container.should eq("ts")
    ensure
      server.close
    end
  end

  it "marks a live media playlist" do
    server = TestHTTPServer.new
    server.on("/index.m3u8") do |_, response|
      response.print(<<-M3U8)
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXTINF:4,
        seg0.ts
      M3U8
    end
    server.start

    begin
      media = extractor.extract(URI.parse("#{server.url}/index.m3u8"), Rill::HTTPClient.new)
      media.validate!

      media.is_live?.should be_true
      media.duration_seconds.should be_nil

      format = media.formats.first
      format.live?.should be_true
      format.duration_seconds.should be_nil
    ensure
      server.close
    end
  end

  it "keeps looking for a variant container" do
    server = TestHTTPServer.new
    server.on("/master.m3u8") do |_, response|
      response.print(<<-M3U8)
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=400000,RESOLUTION=320x180
        low/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
        high/index.m3u8
      M3U8
    end
    server.on("/low/index.m3u8") do |_, response|
      response.print(<<-M3U8)
        #EXTM3U
        #EXTINF:4,
        seg0
        #EXT-X-ENDLIST
      M3U8
    end
    server.on("/high/index.m3u8") do |_, response|
      response.print(<<-M3U8)
        #EXTM3U
        #EXTINF:4,
        seg0.ts
        #EXT-X-ENDLIST
      M3U8
    end
    server.start

    begin
      media = extractor.extract(URI.parse("#{server.url}/master.m3u8"), Rill::HTTPClient.new)
      media.validate!

      media.formats.first.container.should eq("ts")
    ensure
      server.close
    end
  end

  it "rejects live master playlists with separate audio" do
    server = TestHTTPServer.new
    server.on("/master.m3u8") do |_, response|
      response.print(<<-M3U8)
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",URI="audio/en.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720,AUDIO="aud"
        high/index.m3u8
      M3U8
    end
    server.on("/high/index.m3u8") do |_, response|
      response.print(<<-M3U8)
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXTINF:4,
        seg0.ts
      M3U8
    end
    server.start

    begin
      expect_raises(Rill::UnsupportedManifestError, /live HLS with separate audio/) do
        extractor.extract(URI.parse("#{server.url}/master.m3u8"), Rill::HTTPClient.new)
      end
    ensure
      server.close
    end
  end
end
