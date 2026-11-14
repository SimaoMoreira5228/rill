require "../../spec_helper"

private def spotify_track_url : String
  "https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT"
end

describe Rill::Extractors::Spotify do
  it "matches track URLs" do
    extractor = Rill::Extractors::Spotify.new

    extractor.matches?(URI.parse(spotify_track_url)).should be_true
    extractor.matches?(URI.parse("https://open.spotify.com/intl-pt/track/4cOdK2wGLETKBW3PvgPWqT")).should be_true
    extractor.matches?(URI.parse("https://open.spotify.com/album/4cOdK2wGLETKBW3PvgPWqT")).should be_false
    extractor.matches?(URI.parse("https://example.com/track/4cOdK2wGLETKBW3PvgPWqT")).should be_false
  end

  it "resolves metadata and formats from YouTube" do
    server = TestHTTPServer.new
    server.on("/embed/track/4cOdK2wGLETKBW3PvgPWqT") do |_, response|
      response.print(
        %(<script id="__NEXT_DATA__" type="application/json">#{fixture("spotify", "track.json")}</script>),
      )
    end
    server.on("/youtubei/v1/search") do |_, response|
      response.print(fixture("youtube", "search.json"))
    end
    server.on("/watch") do |_, response|
      response.print(%({"VISITOR_DATA":"visitor123","INNERTUBE_API_KEY":"test-key"}))
    end
    server.on("/youtubei/v1/player") do |_, response|
      response.print(fixture("youtube", "player.json"))
    end
    server.start

    begin
      extractor = Rill::Extractors::Spotify.new(
        api_base: server.url,
        youtube: Rill::Extractors::YouTube.new(server.url),
      )
      media = extractor.extract(URI.parse(spotify_track_url), Rill::HTTPClient.new)
      media.validate!

      media.id.should eq("4cOdK2wGLETKBW3PvgPWqT")
      media.title.should eq("Never Gonna Give You Up")
      media.uploader.should eq("Rick Astley")
      media.duration_seconds.not_nil!.should be_close(213.573, 0.001)
      media.thumbnail_url.not_nil!.to_s.should eq("https://image.example/cover-640.jpg")
      media.upload_date.should eq("1987-11-12")
      media.extractor.should eq("spotify")
      media.formats.size.should eq(27)

      media.warnings.size.should eq(1)
      media.warnings.first.should contain("no DRM-free stream")
      media.warnings.first.should contain("dQw4w9WgXcQ")
    ensure
      server.close
    end
  end

  it "reports unplayable tracks as unavailable" do
    body = fixture("spotify", "track.json").sub("\"isPlayable\": true", "\"isPlayable\": false")
    server = TestHTTPServer.new
    server.on("/embed/track/4cOdK2wGLETKBW3PvgPWqT") do |_, response|
      response.print(%(<script id="__NEXT_DATA__" type="application/json">#{body}</script>))
    end
    server.start

    begin
      extractor = Rill::Extractors::Spotify.new(
        api_base: server.url,
        youtube: Rill::Extractors::YouTube.new(server.url),
      )
      expect_raises(Rill::MediaUnavailableError, /not playable/) do
        extractor.extract(URI.parse(spotify_track_url), Rill::HTTPClient.new)
      end
    ensure
      server.close
    end
  end
end
