require "../../spec_helper"

describe Rill::Extractors::DirectMedia do
  extractor = Rill::Extractors::DirectMedia.new

  it "matches media file URLs" do
    extractor.matches?(URI.parse("https://example.com/video.mp4")).should be_true
    extractor.matches?(URI.parse("https://example.com/audio/TRACK.MP3?token=1")).should be_true
    extractor.matches?(URI.parse("http://example.com/stream.webm")).should be_true
  end

  it "does not match pages or unsupported schemes" do
    extractor.matches?(URI.parse("https://example.com/watch")).should be_false
    extractor.matches?(URI.parse("https://example.com/page.html")).should be_false
    extractor.matches?(URI.parse("ftp://example.com/video.mp4")).should be_false
  end

  it "builds a combined video format" do
    url = URI.parse("https://example.com/media/My%20Video.mp4")
    media = extractor.extract(url, Rill::HTTPClient.new)
    media.validate!

    media.title.should eq("My Video")
    media.webpage_url.to_s.should eq(url.to_s)

    format = media.formats.first
    format.kind.should eq(Rill::FormatKind::Combined)
    format.container.should eq("mp4")
    format.format_id.should eq("direct")
    format.url.to_s.should eq(url.to_s)
  end

  it "builds an audio format" do
    url = URI.parse("https://example.com/media/track.flac")
    media = extractor.extract(url, Rill::HTTPClient.new)

    format = media.formats.first
    format.kind.should eq(Rill::FormatKind::Audio)
    format.container.should eq("flac")
  end
end
