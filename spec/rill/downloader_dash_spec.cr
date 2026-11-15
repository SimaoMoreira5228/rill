require "../spec_helper"

describe Rill::Downloader do
  it "downloads DASH initialization and media segments" do
    manifest = <<-XML
      <MPD mediaPresentationDuration="PT8S">
        <Period>
          <AdaptationSet mimeType="video/mp4">
            <SegmentTemplate duration="4" media="seg-$Number$.m4s"
                             initialization="init.mp4"/>
            <Representation id="v" bandwidth="100000"/>
          </AdaptationSet>
        </Period>
      </MPD>
    XML

    server = TestHTTPServer.new
    server.on("/manifest.mpd") { |_, response| response.print(manifest) }
    server.on("/init.mp4") do |_, response|
      response.content_length = 4
      response.print("INIT")
    end
    server.on("/seg-1.m4s") do |_, response|
      response.content_length = 1
      response.print("A")
    end
    server.on("/seg-2.m4s") do |_, response|
      response.content_length = 1
      response.print("B")
    end
    server.start

    begin
      with_temp_dir do |directory|
        target = directory / "video.mp4"
        format = Rill::Format.new(
          format_id: "v",
          url: URI.parse("#{server.url}/manifest.mpd"),
          kind: Rill::FormatKind::Video,
          protocol: Rill::FormatProtocol::Dash,
        )

        downloader.download(format, target)

        File.read(target).should eq("INITAB")
      end
    ensure
      server.close
    end
  end
  it "sends format headers with DASH requests" do
    manifest = <<-XML
      <MPD mediaPresentationDuration="PT4S">
        <Period>
          <AdaptationSet mimeType="video/mp4">
            <SegmentTemplate duration="4" media="seg-$Number$.m4s"
                             initialization="init.mp4"/>
            <Representation id="v" bandwidth="100000"/>
          </AdaptationSet>
        </Period>
      </MPD>
    XML

    seen = [] of String?
    server = TestHTTPServer.new
    server.on("/manifest.mpd") do |request, response|
      seen << request.headers["Referer"]?
      response.print(manifest)
    end
    server.on("/init.mp4") do |request, response|
      seen << request.headers["Referer"]?
      response.print("INIT")
    end
    server.on("/seg-1.m4s") do |request, response|
      seen << request.headers["Referer"]?
      response.print("A")
    end
    server.start

    begin
      with_temp_dir do |directory|
        headers = HTTP::Headers.new
        headers["Referer"] = "https://example.com/page"
        format = Rill::Format.new(
          format_id: "v",
          url: URI.parse("#{server.url}/manifest.mpd"),
          kind: Rill::FormatKind::Video,
          protocol: Rill::FormatProtocol::Dash,
          headers: headers,
        )

        target = directory / "video.mp4"
        downloader.download(format, target)

        File.read(target).should eq("INITA")
        seen.should eq([
          "https://example.com/page",
          "https://example.com/page",
          "https://example.com/page",
        ])
      end
    ensure
      server.close
    end
  end

  it "rejects fragmented MP4 representations without an init section" do
    manifest = <<-XML
      <MPD mediaPresentationDuration="PT4S">
        <Period>
          <AdaptationSet mimeType="video/mp4">
            <SegmentTemplate duration="4" media="seg-$Number$.m4s"/>
            <Representation id="v" bandwidth="100000"/>
          </AdaptationSet>
        </Period>
      </MPD>
    XML

    server = TestHTTPServer.new
    server.on("/manifest.mpd") { |_, response| response.print(manifest) }
    server.start

    begin
      with_temp_dir do |directory|
        target = directory / "video.mp4"
        format = Rill::Format.new(
          format_id: "v",
          url: URI.parse("#{server.url}/manifest.mpd"),
          kind: Rill::FormatKind::Video,
          protocol: Rill::FormatProtocol::Dash,
        )

        expect_raises(Rill::UnsupportedManifestError, /initialization segment/) do
          downloader.download(format, target)
        end
        File.exists?(target).should be_false
      end
    ensure
      server.close
    end
  end
end
