require "../../spec_helper"

private def twitch_clip_body : String
  fixture("twitch", "faint_light_gull_whole_wheat.json")
end

private def twitch_portrait_body : String
  fixture("twitch", "portrait_clip.json")
end

describe Rill::Extractors::TwitchClip do
  it "matches Twitch clip URLs and rejects other Twitch paths" do
    extractor = Rill::Extractors::TwitchClip.new

    extractor.matches?(URI.parse("https://clips.twitch.tv/FaintLightGullWholeWheat")).should be_true
    extractor.matches?(URI.parse("https://clips.twitch.tv/FaintLightGullWholeWheat/")).should be_true
    extractor.matches?(URI.parse("https://clips.twitch.tv/embed?clip=InquisitiveBreakableYogurtJebaited")).should be_true
    extractor.matches?(URI.parse("https://twitch.tv/sergeynixon/clip/StormyThankfulSproutFutureMan")).should be_true
    extractor.matches?(URI.parse("https://www.twitch.tv/sergeynixon/clip/StormyThankfulSproutFutureMan")).should be_true
    extractor.matches?(URI.parse("https://go.twitch.tv/rossbroadcast/clip/ConfidentBraveHumanChefFrank")).should be_true
    extractor.matches?(URI.parse("https://m.twitch.tv/rossbroadcast/clip/ConfidentBraveHumanChefFrank")).should be_true
    extractor.matches?(URI.parse("http://clips.twitch.tv/FaintLightGullWholeWheat")).should be_true

    extractor.matches?(URI.parse("https://clips.twitch.tv/embed")).should be_false
    extractor.matches?(URI.parse("https://clips.twitch.tv/embed?foo=bar")).should be_false
    extractor.matches?(URI.parse("https://clips.twitch.tv/foo/bar")).should be_false
    extractor.matches?(URI.parse("https://clips.twitch.tv/")).should be_false
    extractor.matches?(URI.parse("https://www.twitch.tv/videos/123456789")).should be_false
    extractor.matches?(URI.parse("https://www.twitch.tv/somechannel")).should be_false
    extractor.matches?(URI.parse("https://www.twitch.tv/directory/game/Just%20Chatting")).should be_false
    extractor.matches?(URI.parse("https://www.twitch.tv/somechannel/clip/")).should be_false
    extractor.matches?(URI.parse("https://clips.twitch.tv.evil.com/FaintLightGullWholeWheat")).should be_false
    extractor.matches?(URI.parse("https://example.com/FaintLightGullWholeWheat")).should be_false
    extractor.matches?(URI.parse("https://nottwitch.tv/somechannel/clip/FaintLightGullWholeWheat")).should be_false
    extractor.matches?(URI.parse("ftp://clips.twitch.tv/FaintLightGullWholeWheat")).should be_false
  end

  it "extracts clip metadata and signed formats" do
    server = TestHTTPServer.new
    captured_body = nil
    server.on("/gql") do |request, response|
      captured_body = request.body.try(&.gets_to_end)
      response.headers["Content-Type"] = "application/json"
      response.print(twitch_clip_body)
    end
    server.start

    begin
      extractor = Rill::Extractors::TwitchClip.new("#{server.url}/gql")
      media = extractor.extract(
        URI.parse("https://clips.twitch.tv/FaintLightGullWholeWheat"),
        Rill::HTTPClient.new,
      )
      media.validate!

      request = server.requests.first
      request.method.should eq("POST")
      request.headers["Client-ID"].should eq("ue6666qo983tsx6so1t0vnawi233wa")
      request.headers["Content-Type"].should eq("text/plain;charset=UTF-8")
      captured_body.should eq(
        %([{"operationName":"ShareClipRenderStatus","variables":{"slug":"FaintLightGullWholeWheat"},) +
        %("extensions":{"persistedQuery":{"version":1,) +
        %("sha256Hash":"2db6a3b20eabf510bd3cf465ae2408834b59eb6b8af89ca73ab1486cacecfb63"}}}]),
      )

      media.id.should eq("396245304")
      media.title.should eq("EA Play 2016 Live from the Novo Theatre")
      media.uploader.should eq("stereotype_")
      media.duration_seconds.not_nil!.should be_close(32.1, 0.001)
      media.upload_date.should eq("2016-06-12")
      media.thumbnail_url.not_nil!.to_s.should eq(
        "https://static-cdn.jtvnw.net/twitch-video-assets/twitch-vap-video-assets-prod-us-west-2/" +
        "fecef0d5-0773-41f2-a44d-5522061e0a1f/landscape/thumb/thumb-0000000000-1920x1080.jpg",
      )

      media.formats.size.should eq(1)
      format = media.formats.first
      format.format_id.should eq("1080")
      format.kind.should eq(Rill::FormatKind::Combined)
      format.protocol.should eq(Rill::FormatProtocol::Http)
      format.container.should eq("mp4")
      format.height.should eq(1080)
      format.fps.should be_nil

      parameters = HTTP::Params.parse(format.url.query.not_nil!)
      access_token = JSON.parse(twitch_clip_body)[0]["data"]["clip"]["playbackAccessToken"]
      parameters["sig"].should eq(access_token["signature"].as_s)
      parameters["token"].should eq(access_token["value"].as_s)

      unsigned = format.url.dup
      unsigned.query = nil
      unsigned.to_s.should eq(
        "https://d1ndex63qxojbr.cloudfront.net/nauth/" +
        "fecef0d5-0773-41f2-a44d-5522061e0a1f/landscape/avc/1080/index.mp4",
      )
    ensure
      server.close
    end
  end

  it "adds portrait formats for clips with a portrait asset" do
    server = TestHTTPServer.new
    server.on("/gql") do |_, response|
      response.headers["Content-Type"] = "application/json"
      response.print(twitch_portrait_body)
    end
    server.start

    begin
      extractor = Rill::Extractors::TwitchClip.new("#{server.url}/gql")
      media = extractor.extract(
        URI.parse("https://www.twitch.tv/xqc/clip/CulturedAmazingKuduDatSheffy-TiZ_-ixAGYR3y2Uy"),
        Rill::HTTPClient.new,
      )
      media.validate!

      media.id.should eq("3207364882")
      media.formats.map(&.format_id).should eq([
        "1080",
        "720",
        "480",
        "360",
        "portrait-864",
        "portrait-720",
        "portrait-480",
        "portrait-360",
      ])
      media.formats.map(&.url.to_s).uniq.size.should eq(8)

      portrait = media.formats.find { |format| format.format_id == "portrait-864" }.not_nil!
      portrait.height.should eq(864)
      portrait.url.path.should contain("/portrait/avc/864/index.mp4")

      landscape = media.formats.find { |format| format.format_id == "1080" }.not_nil!
      landscape.url.path.should contain("/landscape/avc/1080/index.mp4")
    ensure
      server.close
    end
  end

  it "reports clips that are no longer available" do
    server = TestHTTPServer.new
    server.on("/gql") do |_, response|
      response.headers["Content-Type"] = "application/json"
      response.print(%([{"data":{"clip":null}}]))
    end
    server.start

    begin
      extractor = Rill::Extractors::TwitchClip.new("#{server.url}/gql")
      expect_raises(Rill::MediaUnavailableError, /clip is unavailable/) do
        extractor.extract(
          URI.parse("https://clips.twitch.tv/FaintLightGullWholeWheat"),
          Rill::HTTPClient.new,
        )
      end
    ensure
      server.close
    end
  end

  it "reports clips without playable formats" do
    body = <<-JSON
      [{
        "data": {
          "clip": {
            "id": "1",
            "title": "Empty clip",
            "assets": [],
            "playbackAccessToken": {
              "signature": "signature",
              "value": "token"
            }
          }
        }
      }]
      JSON

    server = TestHTTPServer.new
    server.on("/gql") do |_, response|
      response.headers["Content-Type"] = "application/json"
      response.print(body)
    end
    server.start

    begin
      extractor = Rill::Extractors::TwitchClip.new("#{server.url}/gql")
      expect_raises(Rill::MediaUnavailableError, /no playable formats/) do
        extractor.extract(
          URI.parse("https://clips.twitch.tv/FaintLightGullWholeWheat"),
          Rill::HTTPClient.new,
        )
      end
    ensure
      server.close
    end
  end
end
