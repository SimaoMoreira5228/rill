require "../../spec_helper"

describe Rill::Extractors::YouTube do
  it "extracts a playlist and follows continuations" do
    browse_bodies = [] of String
    server = TestHTTPServer.new
    server.on("/playlist") do |_, response|
      response.print(%({"VISITOR_DATA":"visitor123","INNERTUBE_API_KEY":"test-key"}))
    end
    server.on("/youtubei/v1/browse") do |request, response|
      body = request.body.try(&.gets_to_end) || ""
      browse_bodies << body

      if body.includes?("next-token")
        response.print(fixture("youtube", "playlist_continuation.json"))
      else
        response.print(fixture("youtube", "playlist.json"))
      end
    end
    server.start

    begin
      extractor = Rill::Extractors::YouTube.new(server.url)
      playlist = extractor.extract(
        URI.parse("https://www.youtube.com/playlist?list=PLtest"),
        Rill::HTTPClient.new,
      ).as(Rill::Playlist)

      playlist.validate!
      playlist.title.should eq("Test playlist")
      playlist.description.should eq("A test playlist")
      playlist.id.should eq("PLtest")
      playlist.entries.map(&.id).should eq(["aaaaaaaaaaa", "bbbbbbbbbbb", "ccccccccccc"])
      playlist.entries.map(&.title).should eq(["First video", "Second video", "Third video"])

      browse_bodies.size.should eq(2)
      browse_bodies[0].should contain(%("browseId":"VLPLtest"))
      browse_bodies[1].should contain(%("continuation":"next-token"))
    ensure
      server.close
    end
  end
end
