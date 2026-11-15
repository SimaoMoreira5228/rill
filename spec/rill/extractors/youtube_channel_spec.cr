require "../../spec_helper"

describe Rill::Extractors::YouTube do
  it "extracts a channel and follows continuations" do
    browse_bodies = [] of String
    server = TestHTTPServer.new
    server.on("/@testchannel/videos") do |_, response|
      response.print(
        %(<script>var ytInitialData = #{fixture("youtube", "channel.json")};</script>) +
        %(<script>"VISITOR_DATA":"visitor123","INNERTUBE_API_KEY":"test-key"</script>),
      )
    end
    server.on("/youtubei/v1/browse") do |request, response|
      body = request.body.try(&.gets_to_end) || ""
      browse_bodies << body

      if body.includes?("channel-next-token")
        response.print(fixture("youtube", "channel_continuation.json"))
      else
        response.print(%({"contents":{}}))
      end
    end
    server.start

    begin
      extractor = Rill::Extractors::YouTube.new(server.url)
      playlist = extractor.extract(
        URI.parse("https://www.youtube.com/@testchannel/videos"),
        Rill::HTTPClient.new,
      ).as(Rill::Playlist)

      playlist.validate!
      playlist.title.should eq("Test channel")
      playlist.description.should eq("A channel used by the specs")
      playlist.id.should eq("UCtestchannel000000000")
      playlist.entries.map(&.id).should eq(["aaaaaaaaaaa", "bbbbbbbbbbb", "ccccccccccc"])
      playlist.entries.map(&.title).should eq(
        ["First channel video", "Second channel video", "Third channel video"],
      )

      browse_bodies.size.should eq(1)
      browse_bodies[0].should contain(%("continuation":"channel-next-token"))
    ensure
      server.close
    end
  end

  it "accepts channel URL shapes and the videos tab only" do
    extractor = Rill::Extractors::YouTube.new

    %w[
      https://www.youtube.com/@NASA
      https://www.youtube.com/@NASA/videos
      https://www.youtube.com/channel/UCabc
      https://www.youtube.com/channel/UCabc/videos
      https://www.youtube.com/user/NASA
      https://www.youtube.com/c/NASA
    ].each do |url|
      extractor.matches?(URI.parse(url)).should be_true
    end

    %w[
      https://www.youtube.com/@NASA/shorts
      https://www.youtube.com/@NASA/streams
      https://www.youtube.com/@NASA/playlists
      https://example.com/@NASA
    ].each do |url|
      extractor.matches?(URI.parse(url)).should be_false
    end
  end
end
