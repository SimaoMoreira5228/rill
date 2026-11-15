require "../../spec_helper"

private def twitch_live_master(base : String) : String
  <<-M3U8
    #EXTM3U
    #EXT-X-TWITCH-INFO:ORIGIN="s3",B="false",REGION="EU"
    #EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="720p60",NAME="720p60",AUTOSELECT=YES,DEFAULT=YES
    #EXT-X-STREAM-INF:BANDWIDTH=2332929,CODECS="avc1.4D401F,mp4a.40.2",RESOLUTION=1280x720,VIDEO="720p60",FRAME-RATE=59.992
    #{base}/vod/720p60/index-dvr.m3u8
  M3U8
end

private def twitch_live_media : String
  <<-M3U8
    #EXTM3U
    #EXT-X-VERSION:6
    #EXT-X-TARGETDURATION:2
    #EXT-X-MAP:URI="init.mp4"
    #EXTINF:2.000,
    0.m4s
    #EXTINF:2.000,
    1.m4s
  M3U8
end

describe Rill::Extractors::TwitchLive do
  it "matches live channel URLs and rejects reserved paths" do
    extractor = Rill::Extractors::TwitchLive.new

    %w[
      https://www.twitch.tv/shroud
      https://twitch.tv/shroud/
      https://m.twitch.tv/shroud
      https://go.twitch.tv/shroud
      https://player.twitch.tv/?channel=shroud
    ].each do |url|
      extractor.matches?(URI.parse(url)).should be_true
    end

    %w[
      https://www.twitch.tv/
      https://www.twitch.tv/directory
      https://www.twitch.tv/videos
      https://www.twitch.tv/videos/635475444
      https://www.twitch.tv/shroud/videos
      https://clips.twitch.tv/FaintLightGullWholeWheat
      https://player.twitch.tv/?video=635475444
      https://example.com/shroud
    ].each do |url|
      extractor.matches?(URI.parse(url)).should be_false
    end
  end

  it "extracts a live stream with live HLS formats" do
    server = TestHTTPServer.new
    bodies = [] of String

    server.on("/gql") do |request, response|
      body = request.body.try(&.gets_to_end) || ""
      bodies << body
      payload = body.includes?("StreamMetadata") ? fixture("twitch", "stream_metadata.json") : fixture("twitch", "stream_token.json")
      response.headers["Content-Type"] = "application/json"
      response.print(payload)
    end
    server.on("/api/channel/hls/shroud.m3u8") do |_, response|
      response.print(twitch_live_master(server.url))
    end
    server.on("/vod/720p60/index-dvr.m3u8") do |_, response|
      response.print(twitch_live_media)
    end
    server.start

    begin
      extractor = Rill::Extractors::TwitchLive.new("#{server.url}/gql", server.url)
      media = extractor.extract(
        URI.parse("https://www.twitch.tv/shroud"),
        Rill::HTTPClient.new,
      )
      media.validate!

      media.id.should eq("319913347671")
      media.title.should eq("shroud")
      media.uploader.should eq("shroud")
      media.upload_date.should eq("2026-11-15")
      media.is_live?.should be_true
      media.formats.size.should eq(1)
      media.formats.first.live?.should be_true
      media.formats.first.container.should eq("mp4")

      bodies.size.should eq(2)
      bodies[0].should contain(%("operationName":"StreamMetadata"))
      bodies[0].should contain(%("channelLogin":"shroud"))
      bodies[1].should contain("streamPlaybackAccessToken")
    ensure
      server.close
    end
  end

  it "reports an offline channel" do
    server = TestHTTPServer.new
    server.on("/gql") do |_, response|
      response.headers["Content-Type"] = "application/json"
      response.print(fixture("twitch", "stream_metadata_offline.json"))
    end
    server.start

    begin
      extractor = Rill::Extractors::TwitchLive.new("#{server.url}/gql", server.url)

      expect_raises(Rill::MediaUnavailableError, /not live/) do
        extractor.extract(URI.parse("https://www.twitch.tv/monstercat"), Rill::HTTPClient.new)
      end
    ensure
      server.close
    end
  end
end
