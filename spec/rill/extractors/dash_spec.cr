require "../../spec_helper"

private def dash_manifest(body : String) : String
  body
end

describe Rill::Extractors::Dash do
  it "matches MPD URLs" do
    extractor = Rill::Extractors::Dash.new

    extractor.matches?(URI.parse("https://example.com/manifest.mpd")).should be_true
    extractor.matches?(URI.parse("https://example.com/MANIFEST.MPD?token=1")).should be_true
    extractor.matches?(URI.parse("https://example.com/manifest.m3u8")).should be_false
    extractor.matches?(URI.parse("ftp://example.com/manifest.mpd")).should be_false
  end

  it "extracts video and audio representations" do
    manifest = dash_manifest(<<-XML)
      <MPD mediaPresentationDuration="PT8S">
        <Period>
          <AdaptationSet mimeType="video/mp4" codecs="avc1.4d401f">
            <SegmentTemplate duration="4" media="video-$Number$.m4s"
                             initialization="video-init.mp4"/>
            <Representation id="v720" bandwidth="1500000" width="1280" height="720" frameRate="30"/>
          </AdaptationSet>
          <AdaptationSet mimeType="audio/mp4" codecs="mp4a.40.2" lang="en">
            <SegmentTemplate duration="4" media="audio-$Number$.m4s"
                             initialization="audio-init.mp4"/>
            <Representation id="a128" bandwidth="128000"/>
          </AdaptationSet>
        </Period>
      </MPD>
    XML

    server = TestHTTPServer.new
    server.on("/manifest.mpd") { |_, response| response.print(manifest) }
    server.start

    begin
      extractor = Rill::Extractors::Dash.new
      media = extractor.extract(URI.parse("#{server.url}/manifest.mpd"), Rill::HTTPClient.new)
      media.validate!

      media.duration_seconds.not_nil!.should eq(8.0)
      media.formats.size.should eq(2)

      video = media.formats.find { |format| format.format_id == "v720" }.not_nil!
      video.kind.should eq(Rill::FormatKind::Video)
      video.protocol.should eq(Rill::FormatProtocol::Dash)
      video.container.should eq("mp4")
      video.height.should eq(720)
      video.video_codec.should eq("avc1.4d401f")
      video.url.to_s.should eq("#{server.url}/manifest.mpd")

      audio = media.formats.find { |format| format.format_id == "a128" }.not_nil!
      audio.kind.should eq(Rill::FormatKind::Audio)
      audio.language.should eq("en")
      audio.audio_codec.should eq("mp4a.40.2")
    ensure
      server.close
    end
  end

  it "reports representations without supported segment information" do
    manifest = dash_manifest(<<-XML)
      <MPD mediaPresentationDuration="PT4S">
        <Period>
          <AdaptationSet mimeType="video/mp4">
            <Representation id="v">
              <SegmentBase indexRange="0-99"/>
            </Representation>
          </AdaptationSet>
        </Period>
      </MPD>
    XML

    server = TestHTTPServer.new
    server.on("/manifest.mpd") { |_, response| response.print(manifest) }
    server.start

    begin
      extractor = Rill::Extractors::Dash.new
      expect_raises(Rill::MediaUnavailableError, /unsupported segment information/) do
        extractor.extract(URI.parse("#{server.url}/manifest.mpd"), Rill::HTTPClient.new)
      end
    ensure
      server.close
    end
  end
end
