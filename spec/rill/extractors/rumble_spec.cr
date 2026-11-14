require "../../spec_helper"

private def rumble_body : String
  fixture("rumble", "embed.html")
end

describe Rill::Extractors::Rumble do
  it "matches Rumble video and embed URLs" do
    extractor = Rill::Extractors::Rumble.new

    extractor.matches?(URI.parse("https://rumble.com/v5pv5f-wmar-2-news-latest-headlines.html")).should be_true
    extractor.matches?(URI.parse("http://www.rumble.com/v5pv5f-wmar-2-news-latest-headlines.html/")).should be_true
    extractor.matches?(URI.parse("https://rumble.com/v5pv5f-wmar-2-news.html?key=value")).should be_true
    extractor.matches?(URI.parse("http://www.rumble.com/vDMUM1?key=value")).should be_true
    extractor.matches?(URI.parse("https://rumble.com/v5pv5f/")).should be_true
    extractor.matches?(URI.parse("https://rumble.com/embed/v5pv5f")).should be_true
    extractor.matches?(URI.parse("http://www.rumble.com/embed/vDMUM1/")).should be_true
    extractor.matches?(URI.parse("https://rumble.com/embed/v5pv5f?pub=abc")).should be_true

    extractor.matches?(URI.parse("https://example.com/embed/v5pv5f")).should be_false
    extractor.matches?(URI.parse("https://rumble.com.evil.com/embed/v5pv5f")).should be_false
    extractor.matches?(URI.parse("https://notrumble.com/embed/v5pv5f")).should be_false
    extractor.matches?(URI.parse("https://rumble.com/c/WMAR")).should be_false
    extractor.matches?(URI.parse("https://rumble.com/videos")).should be_false
    extractor.matches?(URI.parse("https://rumble.com/embed/")).should be_false
    extractor.matches?(URI.parse("https://rumble.com/embed/abc123")).should be_false
    extractor.matches?(URI.parse("https://rumble.com/embed/v5pv5f/extra")).should be_false
    extractor.matches?(URI.parse("ftp://rumble.com/embed/v5pv5f")).should be_false
  end

  it "extracts variants and metadata from the embed page" do
    server = TestHTTPServer.new
    server.on("/embed/v5pv5f") do |_, response|
      response.content_type = "text/html"
      response.print(rumble_body)
    end
    server.start

    begin
      extractor = Rill::Extractors::Rumble.new(server.url)
      media = extractor.extract(
        URI.parse("https://rumble.com/embed/v5pv5f"),
        Rill::HTTPClient.new,
      )
      media.validate!

      media.id.should eq("v5pv5f")
      media.title.should eq("WMAR 2 News Latest Headlines | October 20, 6pm")
      media.uploader.should eq("WMAR")
      media.duration_seconds.not_nil!.should be_close(234.0, 0.01)
      media.thumbnail_url.not_nil!.to_s.should eq(
        "https://hugh.cdn.rumble.cloud/video/s8/1/5/M/z/1/5Mz1a.qR4e-small-WMAR-2-News-Latest-Headline.jpg",
      )
      media.formats.size.should eq(4)
      media.formats.map(&.url.to_s).uniq.size.should eq(4)

      server.requests.map(&.path).should eq(["/embed/v5pv5f"])

      low = media.formats.find { |format| format.format_id == "mp4-360" }.not_nil!
      low.kind.should eq(Rill::FormatKind::Combined)
      low.protocol.should eq(Rill::FormatProtocol::Http)
      low.container.should eq("mp4")
      low.width.should eq(640)
      low.height.should eq(360)
      low.bitrate.should eq(631_i64)
      low.filesize.should eq(18_488_017_i64)

      high = media.formats.find { |format| format.format_id == "mp4-720" }.not_nil!
      high.width.should eq(1280)
      high.height.should eq(720)
      high.bitrate.should eq(1957_i64)
      high.filesize.should eq(57_283_801_i64)

      webm = media.formats.find { |format| format.format_id == "webm-480" }.not_nil!
      webm.container.should eq("webm")
      webm.width.should eq(854)
      webm.height.should eq(480)
      webm.bitrate.should eq(809_i64)
      webm.filesize.should eq(23_682_748_i64)

      base = media.formats.find { |format| format.format_id == "mp4-base" }.not_nil!
      base.container.should eq("mp4")
      base.width.should eq(854)
      base.height.should eq(480)
      base.bitrate.should eq(810_i64)
      base.filesize.should eq(23_720_936_i64)
      base.note.should eq("base")
    ensure
      server.close
    end
  end

  it "follows the embed link from a normal page" do
    server = TestHTTPServer.new
    server.on("/v8c1bt-wmar-2-news-latest-headlines.html") do |_, response|
      response.print(fixture("rumble", "page.html"))
    end
    server.on("/embed/v5pv5f") do |_, response|
      response.print(rumble_body)
    end
    server.start

    begin
      extractor = Rill::Extractors::Rumble.new(server.url)
      media = extractor.extract(
        URI.parse("#{server.url}/v8c1bt-wmar-2-news-latest-headlines.html"),
        Rill::HTTPClient.new,
      )

      media.id.should eq("v5pv5f")
      media.title.should eq("WMAR 2 News Latest Headlines | October 20, 6pm")
      server.requests.map(&.path).should eq([
        "/v8c1bt-wmar-2-news-latest-headlines.html",
        "/embed/v5pv5f",
      ])
    ensure
      server.close
    end
  end

  it "reports pages without an embed link as unavailable" do
    server = TestHTTPServer.new
    server.on("/v8c1bt-wmar-2-news-latest-headlines.html") do |_, response|
      response.print("<html><body>no player</body></html>")
    end
    server.start

    begin
      extractor = Rill::Extractors::Rumble.new(server.url)
      expect_raises(Rill::MediaUnavailableError, /embed URL/) do
        extractor.extract(
          URI.parse("#{server.url}/v8c1bt-wmar-2-news-latest-headlines.html"),
          Rill::HTTPClient.new,
        )
      end
    ensure
      server.close
    end
  end

  it "falls back to the title author segment" do
    body = <<-HTML
      <html>
      <head>
      <title>Example Clip - Example Channel - Rumble</title>
      </head>
      <body>
      <script>
      p.f["vtitle"]={"duration":12,"u":{"mp4":{"url":"https://example.com/clip.mp4","meta":{"bitrate":500,"size":750}}}}
      </script>
      </body>
      </html>
      HTML

    server = TestHTTPServer.new
    server.on("/embed/vtitle") { |_, response| response.print(body) }
    server.start

    begin
      extractor = Rill::Extractors::Rumble.new(server.url)
      media = extractor.extract(URI.parse("https://rumble.com/embed/vtitle"), Rill::HTTPClient.new)

      media.title.should eq("Example Clip - Example Channel")
      media.uploader.should eq("Example Channel")
    ensure
      server.close
    end
  end

  it "reports pages without variants as unavailable" do
    body = <<-HTML
      <html>
      <head>
      <title>Empty Video - Rumble</title>
      </head>
      <body>
      <script>
      p.f["vempty"]={"duration":12,"i":"","title":"Empty Video","ua":{},"u":{}}
      </script>
      </body>
      </html>
      HTML

    server = TestHTTPServer.new
    server.on("/embed/vempty") { |_, response| response.print(body) }
    server.start

    begin
      extractor = Rill::Extractors::Rumble.new(server.url)
      expect_raises(Rill::MediaUnavailableError, /no playable variants/) do
        extractor.extract(URI.parse("https://rumble.com/embed/vempty"), Rill::HTTPClient.new)
      end
    ensure
      server.close
    end
  end
end
