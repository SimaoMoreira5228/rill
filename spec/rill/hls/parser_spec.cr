require "../../spec_helper"

private def parse_playlist(text : String, url : String = "https://example.com/path/master.m3u8")
  Rill::Hls::Parser.parse(text, URI.parse(url))
end

describe Rill::Hls::Parser do
  it "parses a master playlist with attributes and relative URIs" do
    playlist = parse_playlist(<<-M3U8).as(Rill::Hls::MultivariantPlaylist)
      #EXTM3U
      #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI="audio/en.m3u8"
      #EXT-X-STREAM-INF:BANDWIDTH=1280000,AVERAGE-BANDWIDTH=1000000,RESOLUTION=640x360,CODECS="avc1.4d401e,mp4a.40.2",AUDIO="aud"
      low/index.m3u8
      #EXT-X-STREAM-INF:BANDWIDTH=2560000,RESOLUTION=1280x720
      high/index.m3u8
    M3U8

    playlist.variants.size.should eq(2)

    low = playlist.variants[0]
    low.url.to_s.should eq("https://example.com/path/low/index.m3u8")
    low.bandwidth.should eq(1_280_000)
    low.average_bandwidth.should eq(1_000_000)
    low.width.should eq(640)
    low.height.should eq(360)
    low.codecs.should eq("avc1.4d401e,mp4a.40.2")
    low.audio_group.should eq("aud")

    high = playlist.variants[1]
    high.width.should eq(1280)
    high.height.should eq(720)
    high.audio_group.should be_nil

    playlist.renditions.size.should eq(1)
    rendition = playlist.renditions.first
    rendition.type.should eq("AUDIO")
    rendition.group_id.should eq("aud")
    rendition.name.should eq("English")
    rendition.language.should eq("en")
    rendition.url.not_nil!.to_s.should eq("https://example.com/path/audio/en.m3u8")
    rendition.default?.should be_true
    rendition.autoselect?.should be_true
  end

  it "parses a media playlist" do
    playlist = parse_playlist(<<-M3U8, "https://example.com/hls/index.m3u8").as(Rill::Hls::MediaPlaylist)
      #EXTM3U
      #EXT-X-VERSION:7
      #EXT-X-TARGETDURATION:10
      #EXT-X-MAP:URI="init.mp4"
      #EXTINF:9.9,First
      seg0.m4s
      #EXTINF:10,
      seg1.m4s
      #EXT-X-ENDLIST
    M3U8

    playlist.segments.size.should eq(2)
    playlist.segments[0].url.to_s.should eq("https://example.com/hls/seg0.m4s")
    playlist.segments[0].duration.should eq(9.9)
    playlist.segments[0].title.should eq("First")
    playlist.segments[1].title.should be_nil
    playlist.duration_seconds.should be_close(19.9, 0.001)
    playlist.map_url.not_nil!.to_s.should eq("https://example.com/hls/init.mp4")
    playlist.target_duration.should eq(10.0)
    playlist.media_sequence.should eq(0)
    playlist.discontinuity_sequence.should eq(0)
    playlist.ended.should be_true
    playlist.encrypted.should be_false
  end

  it "parses live sequence and discontinuity tags" do
    playlist = parse_playlist(<<-M3U8).as(Rill::Hls::MediaPlaylist)
      #EXTM3U
      #EXT-X-TARGETDURATION:6
      #EXT-X-MEDIA-SEQUENCE:42
      #EXT-X-DISCONTINUITY-SEQUENCE:3
      #EXTINF:6,
      a.ts
      #EXT-X-DISCONTINUITY
      #EXTINF:6,
      b.ts
    M3U8

    playlist.target_duration.should eq(6.0)
    playlist.media_sequence.should eq(42)
    playlist.discontinuity_sequence.should eq(3)
    playlist.segments[0].discontinuity?.should be_false
    playlist.segments[1].discontinuity?.should be_true
    playlist.ended.should be_false
  end

  it "allows an empty live media playlist" do
    playlist = parse_playlist(<<-M3U8).as(Rill::Hls::MediaPlaylist)
      #EXTM3U
      #EXT-X-TARGETDURATION:4
      #EXT-X-MEDIA-SEQUENCE:10
    M3U8

    playlist.segments.should be_empty
    playlist.ended.should be_false
    playlist.media_sequence.should eq(10)
  end

  it "marks encrypted playlists" do
    playlist = parse_playlist(<<-M3U8).as(Rill::Hls::MediaPlaylist)
      #EXTM3U
      #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
      #EXTINF:4,
      seg.ts
      #EXT-X-ENDLIST
    M3U8

    playlist.encrypted.should be_true
  end

  it "allows METHOD=NONE keys" do
    playlist = parse_playlist(<<-M3U8).as(Rill::Hls::MediaPlaylist)
      #EXTM3U
      #EXT-X-KEY:METHOD=NONE
      #EXTINF:4,
      seg.ts
      #EXT-X-ENDLIST
    M3U8

    playlist.encrypted.should be_false
  end

  it "marks live playlists" do
    playlist = parse_playlist(<<-M3U8).as(Rill::Hls::MediaPlaylist)
      #EXTM3U
      #EXTINF:4,
      seg.ts
    M3U8

    playlist.ended.should be_false
  end

  it "parses byte ranges" do
    playlist = parse_playlist(<<-M3U8).as(Rill::Hls::MediaPlaylist)
      #EXTM3U
      #EXT-X-MAP:URI="init.mp4",BYTERANGE="100@0"
      #EXTINF:4,
      #EXT-X-BYTERANGE:500@100
      seg.ts
      #EXT-X-ENDLIST
    M3U8

    playlist.map_byte_range.not_nil!.length.should eq(100)
    playlist.map_byte_range.not_nil!.offset.should eq(0)
    playlist.segments[0].byte_range.not_nil!.length.should eq(500)
    playlist.segments[0].byte_range.not_nil!.offset.should eq(100)
  end

  it "rejects invalid playlists" do
    expect_raises(Rill::ManifestError, /missing #EXTM3U/) do
      parse_playlist("not a playlist")
    end

    expect_raises(Rill::ManifestError, /no segments/) do
      parse_playlist("#EXTM3U\n#EXT-X-ENDLIST")
    end

    expect_raises(Rill::ManifestError, /dangling stream/) do
      parse_playlist("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1")
    end

    expect_raises(Rill::ManifestError, /segment duration/) do
      parse_playlist("#EXTM3U\n#EXTINF:nan,\nseg.ts\n#EXT-X-ENDLIST")
    end

    expect_raises(Rill::ManifestError, /invalid HLS attribute/) do
      parse_playlist("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH\nseg.m3u8")
    end
  end
end
