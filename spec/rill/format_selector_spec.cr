require "../spec_helper"

private def selectable(
  id : String,
  kind : Rill::FormatKind,
  container : String? = nil,
  height : Int32? = nil,
  video_bitrate : Int32? = nil,
  audio_bitrate : Int32? = nil,
  filesize : Int64? = nil,
) : Rill::Format
  Rill::Format.new(
    format_id: id,
    url: URI.parse("https://example.com/#{id}"),
    kind: kind,
    container: container,
    height: height,
    video_bitrate: video_bitrate,
    audio_bitrate: audio_bitrate,
    filesize: filesize,
  )
end

describe Rill::FormatSelector do
  it "prefers combined formats over audio-only formats" do
    formats = [
      selectable("audio", Rill::FormatKind::Audio, "mp3", audio_bitrate: 320),
      selectable("video", Rill::FormatKind::Combined, "mp4", height: 720),
    ]

    Rill::FormatSelector.best(formats).not_nil!.format_id.should eq("video")
  end

  it "picks the highest video" do
    formats = [
      selectable("small", Rill::FormatKind::Combined, "mp4", height: 360),
      selectable("large", Rill::FormatKind::Combined, "avi", height: 1080),
    ]

    Rill::FormatSelector.best(formats).not_nil!.format_id.should eq("large")
  end

  it "uses container rank to break height ties" do
    formats = [
      selectable("avi", Rill::FormatKind::Combined, "avi", height: 720),
      selectable("mp4", Rill::FormatKind::Combined, "mp4", height: 720),
    ]

    Rill::FormatSelector.best(formats).not_nil!.format_id.should eq("mp4")
  end

  it "falls back to audio formats" do
    formats = [
      selectable("low", Rill::FormatKind::Audio, "mp3", audio_bitrate: 128),
      selectable("high", Rill::FormatKind::Audio, "mp3", audio_bitrate: 320),
    ]

    Rill::FormatSelector.best(formats).not_nil!.format_id.should eq("high")
  end

  it "finds formats by id" do
    formats = [
      selectable("first", Rill::FormatKind::Combined, "mp4", height: 360),
      selectable("second", Rill::FormatKind::Combined, "mp4", height: 720),
    ]

    Rill::FormatSelector.by_id(formats, "second").not_nil!.format_id.should eq("second")
    Rill::FormatSelector.by_id(formats, "missing").should be_nil
  end

  it "builds a plan for split video and audio" do
    formats = [
      selectable("video", Rill::FormatKind::Video, "mp4", height: 1080),
      selectable("webm-audio", Rill::FormatKind::Audio, "webm", audio_bitrate: 160),
      selectable("mp4-audio", Rill::FormatKind::Audio, "mp4", audio_bitrate: 128),
    ]

    plan = Rill::FormatSelector.plan(formats).not_nil!
    plan.stream.format_id.should eq("video")
    plan.audio.not_nil!.format_id.should eq("mp4-audio")
    plan.requires_merge?.should be_true
  end

  it "uses a combined format without a separate audio track" do
    formats = [
      selectable("combined", Rill::FormatKind::Combined, "mp4", height: 720),
      selectable("audio", Rill::FormatKind::Audio, "mp4", audio_bitrate: 128),
    ]

    plan = Rill::FormatSelector.plan(formats).not_nil!
    plan.stream.format_id.should eq("combined")
    plan.audio.should be_nil
    plan.requires_merge?.should be_false
  end

  it "plans an audio-only result" do
    formats = [
      selectable("audio", Rill::FormatKind::Audio, "mp3", audio_bitrate: 320),
    ]

    plan = Rill::FormatSelector.plan(formats).not_nil!
    plan.stream.format_id.should eq("audio")
    plan.audio.should be_nil
  end

  it "pairs audio with an explicitly selected video" do
    formats = [
      selectable("video", Rill::FormatKind::Video, "webm", height: 720),
      selectable("audio", Rill::FormatKind::Audio, "webm", audio_bitrate: 128),
    ]

    plan = Rill::FormatSelector.plan(formats, "video").not_nil!
    plan.stream.format_id.should eq("video")
    plan.audio.not_nil!.format_id.should eq("audio")
  end

  it "returns nil for an empty list" do
    Rill::FormatSelector.best([] of Rill::Format).should be_nil
  end
end
