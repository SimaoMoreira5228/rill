require "../spec_helper"

private def playlist_entry(url : String, title : String? = nil, error : String? = nil) : Rill::PlaylistEntry
  Rill::PlaylistEntry.new(
    url: URI.parse(url),
    title: title,
    error: error,
  )
end

describe Rill::Playlist do
  it "accepts a valid playlist" do
    playlist = Rill::Playlist.new(
      title: "Example",
      webpage_url: URI.parse("https://example.com/list"),
      extractor: "example",
      entries: [
        playlist_entry("https://example.com/one", "One"),
        playlist_entry("https://example.com/two", "Two"),
      ],
    )

    playlist.validate!
  end

  it "rejects empty playlists" do
    playlist = Rill::Playlist.new(
      title: "Example",
      webpage_url: URI.parse("https://example.com/list"),
      extractor: "example",
      entries: [] of Rill::PlaylistEntry,
    )

    expect_raises(Rill::InvalidExtractionError, /no entries/) do
      playlist.validate!
    end
  end

  it "rejects non-HTTP entries" do
    playlist = Rill::Playlist.new(
      title: "Example",
      webpage_url: URI.parse("https://example.com/list"),
      extractor: "example",
      entries: [playlist_entry("ftp://example.com/one")],
    )

    expect_raises(Rill::InvalidExtractionError, /non-HTTP URL/) do
      playlist.validate!
    end
  end

  it "rejects entries with both media and an error" do
    media = Rill::Media.new(
      title: "One",
      webpage_url: URI.parse("https://example.com/one"),
      extractor: "example",
      formats: [
        Rill::Format.new(format_id: "f", url: URI.parse("https://example.com/one.mp4")),
      ],
    )
    entry = Rill::PlaylistEntry.new(
      url: URI.parse("https://example.com/one"),
      media: media,
      error: "failed",
    )

    playlist = Rill::Playlist.new(
      title: "Example",
      webpage_url: URI.parse("https://example.com/list"),
      extractor: "example",
      entries: [entry],
    )

    expect_raises(Rill::InvalidExtractionError, /both media and an error/) do
      playlist.validate!
    end
  end

  it "serializes to JSON" do
    playlist = Rill::Playlist.new(
      id: "list-id",
      title: "Example",
      webpage_url: URI.parse("https://example.com/list"),
      extractor: "example",
      entries: [
        playlist_entry("https://example.com/one", "One"),
        playlist_entry("https://example.com/two", nil, "failed"),
      ],
    )

    parsed = JSON.parse(playlist.to_pretty_json)
    parsed["id"].should eq("list-id")
    parsed["title"].should eq("Example")
    parsed["extractor"].should eq("example")

    entries = parsed["entries"].as_a
    entries.size.should eq(2)
    entries[0]["url"].should eq("https://example.com/one")
    entries[0]["title"].should eq("One")
    entries[1]["error"].should eq("failed")
  end
end
