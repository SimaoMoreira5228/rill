require "../../spec_helper"

describe Rill::Extractors::Generic do
  it "extracts page metadata and direct media links" do
    server = TestHTTPServer.new
    server.on("/page") do |_, response|
      response.content_type = "text/html"
      response.print(fixture("generic", "og_video.html"))
    end
    server.start

    begin
      extractor = Rill::Extractors::Generic.new
      media = extractor.extract(URI.parse("#{server.url}/page"), Rill::HTTPClient.new)
      media.validate!

      media.title.should eq("Example Video")
      media.description.should eq("Example description")
      media.uploader.should eq("Example Site")
      media.duration_seconds.not_nil!.should eq(42.0)
      media.thumbnail_url.not_nil!.to_s.should eq("#{server.url}/poster.jpg")
      media.formats.size.should eq(4)

      video = media.formats.find { |format| format.container == "mp4" }.not_nil!
      video.url.to_s.should eq("#{server.url}/media/clip.mp4")
      video.kind.should eq(Rill::FormatKind::Combined)
      video.width.should eq(1280)
      video.height.should eq(720)
      video.duration_seconds.not_nil!.should eq(42.0)
      video.note.should eq("og:video")

      audio = media.formats.find { |format| format.container == "mp3" }.not_nil!
      audio.kind.should eq(Rill::FormatKind::Audio)
      audio.url.to_s.should eq("#{server.url}/audio/track.mp3")

      webm = media.formats.find { |format| format.container == "webm" }.not_nil!
      webm.url.to_s.should eq("#{server.url}/media/alt.webm")

      ogg = media.formats.find { |format| format.container == "ogg" }.not_nil!
      ogg.kind.should eq(Rill::FormatKind::Audio)
    ensure
      server.close
    end
  end

  it "is used by the default registry for pages" do
    server = TestHTTPServer.new
    server.on("/page") do |_, response|
      response.content_type = "text/html"
      response.print(fixture("generic", "og_video.html"))
    end
    server.start

    begin
      result = Rill::ExtractorRegistry.default.extract(URI.parse("#{server.url}/page"))
      media = result.as(Rill::Media)

      media.extractor.should eq("generic")
      media.formats.size.should eq(4)
    ensure
      server.close
    end
  end

  it "accepts a direct media response without a file extension" do
    server = TestHTTPServer.new
    server.on("/stream") do |_, response|
      response.content_type = "video/mp4"
      response.print("x" * 100)
    end
    server.start

    begin
      extractor = Rill::Extractors::Generic.new
      media = extractor.extract(URI.parse("#{server.url}/stream"), Rill::HTTPClient.new)

      media.title.should eq("stream")
      media.formats.size.should eq(1)

      format = media.formats.first
      format.container.should eq("mp4")
      format.kind.should eq(Rill::FormatKind::Combined)
      format.filesize.should eq(100)
    ensure
      server.close
    end
  end

  it "uses declared media types for extensionless links" do
    server = TestHTTPServer.new
    server.on("/page") do |_, response|
      response.content_type = "text/html"
      response.print(<<-HTML)
        <html>
          <head>
            <meta property="og:video" content="/stream">
            <meta property="og:video:type" content="video/webm">
          </head>
          <body>
            <video><source src="/live" type="audio/ogg; codecs=opus"></video>
          </body>
        </html>
        HTML
    end
    server.start

    begin
      media = Rill::Extractors::Generic.new.extract(
        URI.parse("#{server.url}/page"),
        Rill::HTTPClient.new,
      )

      media.formats.size.should eq(2)

      video = media.formats.find { |format| format.container == "webm" }.not_nil!
      video.url.to_s.should eq("#{server.url}/stream")
      video.kind.should eq(Rill::FormatKind::Combined)

      audio = media.formats.find { |format| format.container == "ogg" }.not_nil!
      audio.url.to_s.should eq("#{server.url}/live")
      audio.kind.should eq(Rill::FormatKind::Audio)
    ensure
      server.close
    end
  end

  it "reads schema.org structured data" do
    server = TestHTTPServer.new
    server.on("/page") do |_, response|
      response.content_type = "text/html"
      response.print(<<-HTML)
        <html>
          <head>
            <script type="application/ld+json">
              {
                "@context": "https://schema.org",
                "@type": "VideoObject",
                "name": "Structured Video",
                "description": "Structured description",
                "duration": "PT3M33S",
                "thumbnailUrl": "/poster.jpg",
                "uploadDate": "2024-01-02T10:00:00Z",
                "author": {"@type": "Person", "name": "Structured Author"},
                "width": {"@type": "QuantitativeValue", "value": 1280},
                "height": 720,
                "contentUrl": "/media/stream",
                "encodingFormat": "video/mp4"
              }
            </script>
          </head>
        </html>
        HTML
    end
    server.start

    begin
      media = Rill::Extractors::Generic.new.extract(
        URI.parse("#{server.url}/page"),
        Rill::HTTPClient.new,
      )

      media.title.should eq("Structured Video")
      media.description.should eq("Structured description")
      media.uploader.should eq("Structured Author")
      media.upload_date.should eq("2024-01-02")
      media.duration_seconds.not_nil!.should eq(213.0)
      media.formats.size.should eq(1)

      format = media.formats.first
      format.url.to_s.should eq("#{server.url}/media/stream")
      format.container.should eq("mp4")
      format.width.should eq(1280)
      format.height.should eq(720)
      format.kind.should eq(Rill::FormatKind::Combined)
    ensure
      server.close
    end
  end

  it "reports pages without media links" do
    server = TestHTTPServer.new
    server.on("/page") do |_, response|
      response.content_type = "text/html"
      response.print("<html><body><a href=\"/nope\">nope</a></body></html>")
    end
    server.start

    begin
      extractor = Rill::Extractors::Generic.new
      expect_raises(Rill::MediaUnavailableError, /no direct media links/) do
        extractor.extract(URI.parse("#{server.url}/page"), Rill::HTTPClient.new)
      end
    ensure
      server.close
    end
  end
end
