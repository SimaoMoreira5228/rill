require "../spec_helper"

private def format(
  id : String = "video",
  url : String = "https://example.com/video.mp4",
  kind : Rill::FormatKind = Rill::FormatKind::Video,
) : Rill::Format
  Rill::Format.new(
    format_id: id,
    url: URI.parse(url),
    kind: kind,
    container: "mp4",
  )
end

private def media(formats : Array(Rill::Format) = [format]) : Rill::Media
  Rill::Media.new(
    id: "item-id",
    title: "Example",
    description: "An example item",
    webpage_url: URI.parse("https://example.com/watch"),
    uploader: "Example Uploader",
    duration_seconds: 12.5,
    thumbnail_url: URI.parse("https://example.com/thumb.jpg"),
    upload_date: "2024-02-03",
    extractor: "example",
    formats: formats,
  )
end

describe Rill::Media do
  it "accepts a complete result" do
    media.validate!
  end

  it "rejects an empty title" do
    item = Rill::Media.new(
      title: "",
      webpage_url: URI.parse("https://example.com/watch"),
      extractor: "example",
      formats: [format],
    )

    expect_raises(Rill::InvalidExtractionError, /title is empty/) do
      item.validate!
    end
  end

  it "rejects an empty format list" do
    item = Rill::Media.new(
      title: "Example",
      webpage_url: URI.parse("https://example.com/watch"),
      extractor: "example",
      formats: [] of Rill::Format,
    )

    expect_raises(Rill::InvalidExtractionError, /no formats/) do
      item.validate!
    end
  end

  it "rejects duplicate format ids" do
    item = media([
      format(id: "same"),
      format(id: "same"),
    ])

    expect_raises(Rill::InvalidExtractionError, /duplicate format id/) do
      item.validate!
    end
  end

  it "rejects non-HTTP format URLs" do
    item = media([format(url: "ftp://example.com/video.mp4")])

    expect_raises(Rill::InvalidExtractionError, /non-HTTP URL/) do
      item.validate!
    end
  end

  it "rejects format URLs without a host" do
    item = media([format(url: "/video.mp4")])

    expect_raises(Rill::InvalidExtractionError, /no host/) do
      item.validate!
    end
  end

  it "serializes to JSON" do
    parsed = JSON.parse(media.to_pretty_json)

    parsed["id"].should eq("item-id")
    parsed["title"].should eq("Example")
    parsed["webpage_url"].should eq("https://example.com/watch")
    parsed["thumbnail_url"].should eq("https://example.com/thumb.jpg")
    parsed["duration_seconds"].should eq(12.5)
    parsed["extractor"].should eq("example")

    formats = parsed["formats"].as_a
    formats.size.should eq(1)
    formats.first["format_id"].should eq("video")
    formats.first["kind"].should eq("video")
    formats.first["container"].should eq("mp4")
  end
end
