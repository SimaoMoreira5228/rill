require "../../spec_helper"

private def parse_dash(xml : String, url : String = "https://example.com/path/manifest.mpd")
  Rill::Dash::Parser.parse(xml, URI.parse(url))
end

describe Rill::Dash::Parser do
  it "expands a fixed-duration segment template" do
    manifest = parse_dash(<<-XML)
      <MPD mediaPresentationDuration="PT10S">
        <Period>
          <AdaptationSet mimeType="video/mp4">
            <SegmentTemplate timescale="1" duration="4" startNumber="1"
                             initialization="init.mp4" media="seg-$Number$.m4s"/>
            <Representation id="video" bandwidth="1000000" width="640" height="360"/>
          </AdaptationSet>
        </Period>
      </MPD>
    XML

    manifest.duration_seconds.not_nil!.should eq(10.0)
    manifest.representations.size.should eq(1)

    representation = manifest.representations.first
    representation.reference.should eq("video")
    representation.mime.not_nil!.video?.should be_true
    representation.supported?.should be_true

    init_url, segments = representation.expand
    init_url.not_nil!.to_s.should eq("https://example.com/path/init.mp4")
    segments.map(&.url.to_s).should eq([
      "https://example.com/path/seg-1.m4s",
      "https://example.com/path/seg-2.m4s",
      "https://example.com/path/seg-3.m4s",
    ])
    segments.first.duration_seconds.should eq(4.0)
  end

  it "expands a segment timeline" do
    manifest = parse_dash(<<-XML)
      <MPD mediaPresentationDuration="PT6S">
        <Period>
          <AdaptationSet mimeType="video/mp4">
            <SegmentTemplate timescale="1000" startNumber="10"
                             initialization="init-$RepresentationID$.mp4"
                             media="$RepresentationID$-$Number%03d$-$Time$.m4s">
              <SegmentTimeline>
                <S t="0" d="2000" r="2"/>
              </SegmentTimeline>
            </SegmentTemplate>
            <Representation id="v" bandwidth="2000000"/>
          </AdaptationSet>
        </Period>
      </MPD>
    XML

    representation = manifest.representations.first
    init_url, segments = representation.expand
    init_url.not_nil!.to_s.should eq("https://example.com/path/init-v.mp4")
    segments.map(&.url.to_s).should eq([
      "https://example.com/path/v-010-0.m4s",
      "https://example.com/path/v-011-2000.m4s",
      "https://example.com/path/v-012-4000.m4s",
    ])
    segments.map(&.duration_seconds).should eq([2.0, 2.0, 2.0])
  end

  it "expands a segment list" do
    manifest = parse_dash(<<-XML)
      <MPD mediaPresentationDuration="PT4S">
        <Period>
          <AdaptationSet mimeType="audio/mp4">
            <Representation id="audio" bandwidth="128000">
              <SegmentList>
                <Initialization sourceURL="init.mp4"/>
                <SegmentURL media="a.m4s"/>
                <SegmentURL media="b.m4s"/>
              </SegmentList>
            </Representation>
          </AdaptationSet>
        </Period>
      </MPD>
    XML

    representation = manifest.representations.first
    init_url, segments = representation.expand
    init_url.not_nil!.to_s.should eq("https://example.com/path/init.mp4")
    segments.map(&.url.to_s).should eq([
      "https://example.com/path/a.m4s",
      "https://example.com/path/b.m4s",
    ])
  end

  it "resolves inherited base URLs" do
    manifest = parse_dash(<<-XML)
      <MPD mediaPresentationDuration="PT4S">
        <BaseURL>https://cdn.example.com/base/</BaseURL>
        <Period>
          <AdaptationSet mimeType="video/mp4">
            <SegmentTemplate duration="2" media="seg-$Number$.m4s"/>
            <Representation id="v"/>
          </AdaptationSet>
        </Period>
      </MPD>
    XML

    _, segments = manifest.representations.first.expand
    segments.first.url.to_s.should eq("https://cdn.example.com/base/seg-1.m4s")
  end

  it "rejects unsupported manifests" do
    expect_raises(Rill::UnsupportedManifestError, /live DASH/) do
      parse_dash(%(<MPD type="dynamic"><Period/></MPD>))
    end

    expect_raises(Rill::UnsupportedManifestError, /multi-period/) do
      parse_dash(%(<MPD><Period/><Period/></MPD>))
    end

    expect_raises(Rill::ManifestError, /MPD root/) do
      parse_dash("<")
    end

    expect_raises(Rill::UnsupportedManifestError, /byte-range/) do
      parse_dash(<<-XML)
        <MPD mediaPresentationDuration="PT4S">
          <Period>
            <AdaptationSet mimeType="video/mp4">
              <Representation id="v">
                <SegmentList>
                  <SegmentURL media="a.m4s" mediaRange="0-99"/>
                </SegmentList>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
      XML
    end
  end

  it "skips protected and SegmentBase representations" do
    manifest = parse_dash(<<-XML)
      <MPD mediaPresentationDuration="PT4S">
        <Period>
          <AdaptationSet mimeType="video/mp4">
            <ContentProtection schemeIdUri="urn:mpeg:dash:mp4protection:2011"/>
          </AdaptationSet>
          <AdaptationSet mimeType="audio/mp4">
            <Representation id="a">
              <SegmentBase indexRange="0-99"/>
            </Representation>
          </AdaptationSet>
        </Period>
      </MPD>
    XML

    manifest.representations.size.should eq(1)
    manifest.representations.first.supported?.should be_false
  end

  it "parses ISO 8601 durations" do
    Rill::Dash.parse_duration("PT10S").should eq(10.0)
    Rill::Dash.parse_duration("PT1H2M3.5S").should eq(3723.5)
    Rill::Dash.parse_duration("P1DT2H").should eq(93600.0)
    Rill::Dash.parse_duration("PT0.5S").should eq(0.5)
    Rill::Dash.parse_duration("P1M").should be_nil
    Rill::Dash.parse_duration("nope").should be_nil
  end
end
