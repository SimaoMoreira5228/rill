require "../../spec_helper"

private def twitch_vod_master(base : String) : String
  <<-M3U8
    #EXTM3U
    #EXT-X-TWITCH-INFO:ORIGIN="s3",B="false",REGION="EU"
    #EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="720p60",NAME="720p60",AUTOSELECT=YES,DEFAULT=YES
    #EXT-X-STREAM-INF:BANDWIDTH=2332929,CODECS="avc1.4D401F,mp4a.40.2",RESOLUTION=1280x720,VIDEO="720p60",FRAME-RATE=59.992
    #{base}/vod/720p60/index-dvr.m3u8
    #EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="360p30",NAME="360p",AUTOSELECT=YES,DEFAULT=YES
    #EXT-X-STREAM-INF:BANDWIDTH=657846,CODECS="avc1.4D401E,mp4a.40.2",RESOLUTION=640x360,VIDEO="360p30",FRAME-RATE=29.996
    #{base}/vod/360p30/index-dvr.m3u8
  M3U8
end

private def twitch_vod_media : String
  <<-M3U8
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-TARGETDURATION:10
    #EXT-X-PLAYLIST-TYPE:EVENT
    #EXTINF:10.000,
    0.ts
    #EXTINF:10.000,
    1.ts
    #EXT-X-ENDLIST
  M3U8
end

describe Rill::Extractors::TwitchVod do
  it "matches Twitch VOD URL shapes" do
    extractor = Rill::Extractors::TwitchVod.new

    %w[
      https://www.twitch.tv/videos/635475444
      https://twitch.tv/videos/635475444/
      https://m.twitch.tv/videos/635475444
      https://go.twitch.tv/riotgames/v/635475444
      https://www.twitch.tv/riotgames/video/635475444
      https://player.twitch.tv/?video=635475444
      https://player.twitch.tv/?video=v635475444
    ].each do |url|
      extractor.matches?(URI.parse(url)).should be_true
    end

    %w[
      https://www.twitch.tv/riotgames
      https://www.twitch.tv/videos/abc
      https://clips.twitch.tv/FaintLightGullWholeWheat
      https://www.twitch.tv/sergeynixon/clip/StormyThankfulSproutFutureMan
      https://player.twitch.tv/?channel=riotgames
      https://example.com/videos/635475444
      ftp://www.twitch.tv/videos/635475444
    ].each do |url|
      extractor.matches?(URI.parse(url)).should be_false
    end
  end

  it "extracts VOD metadata and HLS formats" do
    server = TestHTTPServer.new
    bodies = [] of String

    server.on("/gql") do |request, response|
      body = request.body.try(&.gets_to_end) || ""
      bodies << body
      response.headers["Content-Type"] = "application/json"
      response.print(
        body.includes?("VideoMetadata") ? fixture("twitch", "vod_metadata.json") : fixture("twitch", "vod_token.json"),
      )
    end
    server.on("/vod/635475444.m3u8") do |_, response|
      response.print(twitch_vod_master(server.url))
    end
    {"/vod/720p60/index-dvr.m3u8", "/vod/360p30/index-dvr.m3u8"}.each do |path|
      server.on(path) do |_, response|
        response.print(twitch_vod_media)
      end
    end
    server.start

    begin
      extractor = Rill::Extractors::TwitchVod.new("#{server.url}/gql", server.url)
      media = extractor.extract(
        URI.parse("https://www.twitch.tv/videos/635475444"),
        Rill::HTTPClient.new,
      )
      media.validate!

      media.id.should eq("635475444")
      media.title.should eq("Riot Games")
      media.description.should eq("A recorded broadcast")
      media.uploader.should eq("Riot Games")
      media.duration_seconds.not_nil!.should be_close(11643.0, 0.001)
      media.upload_date.should eq("2020-05-29")
      media.thumbnail_url.not_nil!.to_s.should eq(
        "https://static-cdn.jtvnw.net/cf_vods/example/thumb0-0x0.jpg",
      )

      media.formats.size.should eq(2)
      media.formats.map(&.format_id).should eq(["hls-1", "hls-2"])
      media.formats.map(&.height).should eq([720, 360])
      media.formats.first.url.to_s.should eq("#{server.url}/vod/720p60/index-dvr.m3u8")

      bodies.size.should eq(2)
      bodies[0].should contain(%("operationName":"VideoMetadata"))
      bodies[0].should contain(%("videoID":"635475444"))
      bodies[1].should contain("videoPlaybackAccessToken")
      bodies[1].should contain(%(playerType: \\"site\\"))
    ensure
      server.close
    end
  end
end
