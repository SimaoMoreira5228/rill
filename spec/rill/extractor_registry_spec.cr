require "../spec_helper"

module SpecExtractors
  class First < Rill::Extractor
    def name : String
      "first"
    end

    def matches?(url : URI) : Bool
      true
    end

    def extract(url : URI, client : Rill::HTTPClient) : Rill::Media
      Rill::Media.new(
        title: "first",
        webpage_url: url,
        extractor: name,
        formats: [
          Rill::Format.new(format_id: "f", url: url),
        ],
      )
    end
  end

  class Second < First
    def name : String
      "second"
    end
  end

  class Broken < Rill::Extractor
    def name : String
      "broken"
    end

    def matches?(url : URI) : Bool
      true
    end

    def extract(url : URI, client : Rill::HTTPClient) : Rill::Media
      Rill::Media.new(
        title: "broken",
        webpage_url: url,
        extractor: name,
        formats: [] of Rill::Format,
      )
    end
  end
end

describe Rill::ExtractorRegistry do
  it "uses registration order when extractors overlap" do
    registry = Rill::ExtractorRegistry.new
    registry.register(SpecExtractors::First)
    registry.register(SpecExtractors::Second)

    registry.extractor_for("https://example.com/video").should eq(SpecExtractors::First)
    registry.extract("https://example.com/video").title.should eq("first")
  end

  it "routes built-in extractors" do
    registry = Rill::ExtractorRegistry.default

    registry.extractor_for("https://archive.org/details/BigBuckBunny_124")
      .should eq(Rill::Extractors::InternetArchive)
    registry.extractor_for("https://media.ccc.de/v/39c3-opening")
      .should eq(Rill::Extractors::MediaCccDe)
    registry.extractor_for("https://example.com/w/abc123")
      .should eq(Rill::Extractors::PeerTube)
    registry.extractor_for("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
      .should eq(Rill::Extractors::YouTube)
    registry.extractor_for("https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT")
      .should eq(Rill::Extractors::Spotify)
    registry.extractor_for("https://benprunty.bandcamp.com/track/lanius-battle")
      .should eq(Rill::Extractors::Bandcamp)
    registry.extractor_for("https://blazo.bandcamp.com/album/jazz-format-mixtape-vol-1")
      .should eq(Rill::Extractors::Bandcamp)
    registry.extractor_for("https://rumble.com/v5pv5f-wmar-2-news-latest-headlines.html")
      .should eq(Rill::Extractors::Rumble)
    registry.extractor_for("https://rumble.com/embed/v5pv5f")
      .should eq(Rill::Extractors::Rumble)
    registry.extractor_for("https://example.com/clip.mp4")
      .should eq(Rill::Extractors::DirectMedia)
    registry.extractor_for("https://example.com/playlist.m3u8")
      .should eq(Rill::Extractors::Hls)
    registry.extractor_for("https://example.com/list.m3u")
      .should eq(Rill::Extractors::M3u)
    registry.extractor_for("https://example.com/manifest.mpd")
      .should eq(Rill::Extractors::Dash)
    registry.extractor_for("https://example.com/watch")
      .should eq(Rill::Extractors::Generic)
    registry.extractors.last.should eq(Rill::Extractors::Generic)
  end

  it "rejects unsupported URLs" do
    registry = Rill::ExtractorRegistry.new

    expect_raises(Rill::UnsupportedUrlError) do
      registry.extract("https://example.com/watch")
    end

    expect_raises(Rill::UnsupportedUrlError) do
      registry.extract("ftp://example.com/watch")
    end

    expect_raises(Rill::UnsupportedUrlError) do
      registry.extract("not a url")
    end
  end

  it "validates extractor output at the boundary" do
    registry = Rill::ExtractorRegistry.new
    registry.register(SpecExtractors::Broken)

    expect_raises(Rill::InvalidExtractionError, /no formats/) do
      registry.extract("https://example.com/video")
    end
  end
end
