require "file_utils"

require "../spec_helper"

private def ffmpeg_available? : Bool
  Process.run(
    "ffmpeg",
    ["-version"],
    output: Process::Redirect::Close,
    error: Process::Redirect::Close,
  ).success?
rescue File::Error
  false
end

private def ffprobe_available? : Bool
  Process.run(
    "ffprobe",
    ["-version"],
    output: Process::Redirect::Close,
    error: Process::Redirect::Close,
  ).success?
rescue File::Error
  false
end

private def generate_inputs(directory : Path) : Tuple(Path, Path)
  video = directory / "video.mp4"
  audio = directory / "audio.m4a"

  Process.run(
    "ffmpeg",
    [
      "-hide_banner", "-loglevel", "error", "-y",
      "-f", "lavfi", "-i", "color=c=black:s=160x120:d=1",
      "-an", "-c:v", "mpeg4", video.to_s,
    ],
    output: Process::Redirect::Close,
    error: Process::Redirect::Close,
  ).success?.should be_true

  Process.run(
    "ffmpeg",
    [
      "-hide_banner", "-loglevel", "error", "-y",
      "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
      "-vn", "-c:a", "aac", audio.to_s,
    ],
    output: Process::Redirect::Close,
    error: Process::Redirect::Close,
  ).success?.should be_true

  {video, audio}
end

private def stream_types(path : Path) : Array(String)
  output = IO::Memory.new
  Process.run(
    "ffprobe",
    [
      "-v", "error",
      "-show_entries", "stream=codec_type",
      "-of", "csv=p=0",
      path.to_s,
    ],
    output: output,
    error: Process::Redirect::Close,
  )

  output.to_s.lines.map(&.strip).reject(&.empty?)
end

private def with_media_directory(&)
  directory = File.join(Dir.tempdir, "rill-mux-spec-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(directory)

  begin
    yield Path.new(directory)
  ensure
    FileUtils.rm_rf(directory)
  end
end

describe Rill::MediaMuxer do
  it "merges via system ffmpeg" do
    unless ffmpeg_available?
      pending "ffmpeg is not installed"
      next
    end

    with_media_directory do |directory|
      video, audio = generate_inputs(directory)
      output = directory / "merged.mp4"

      Rill::MediaMuxer.new(Rill::MediaMuxer::Backend::System)
        .merge(video, audio, output)

      File.size(output).should be > 0
      if ffprobe_available?
        types = stream_types(output)
        types.should contain("video")
        types.should contain("audio")
      end
    end
  end

  it "merges via the helper" do
    helper = Path.new("build/rill-media")

    unless File.file?(helper)
      pending "build the helper with make media-helper"
      next
    end

    unless ffmpeg_available?
      pending "ffmpeg is not installed"
      next
    end

    with_media_directory do |directory|
      video, audio = generate_inputs(directory)
      output = directory / "merged.mp4"

      Rill::MediaMuxer.new(
        Rill::MediaMuxer::Backend::Helper,
        helper_path: helper.to_s,
      ).merge(video, audio, output)

      File.size(output).should be > 0
      if ffprobe_available?
        types = stream_types(output)
        types.should contain("video")
        types.should contain("audio")
      end
    end
  end

  it "refuses to overwrite an existing output" do
    unless ffmpeg_available?
      pending "ffmpeg is not installed"
      next
    end

    with_media_directory do |directory|
      video, audio = generate_inputs(directory)
      output = directory / "merged.mp4"
      File.write(output, "existing")

      expect_raises(Rill::FileExistsError) do
        Rill::MediaMuxer.new(Rill::MediaMuxer::Backend::System)
          .merge(video, audio, output)
      end
      File.read(output).should eq("existing")
    end
  end

  it "overwrites when asked" do
    unless ffmpeg_available?
      pending "ffmpeg is not installed"
      next
    end

    with_media_directory do |directory|
      video, audio = generate_inputs(directory)
      output = directory / "merged.mp4"
      muxer = Rill::MediaMuxer.new(Rill::MediaMuxer::Backend::System)

      muxer.merge(video, audio, output)
      muxer.merge(video, audio, output, overwrite: true)

      File.size(output).should be > 0
    end
  end

  it "reports missing inputs" do
    muxer = Rill::MediaMuxer.new(Rill::MediaMuxer::Backend::Off)

    expect_raises(Rill::MediaMuxError, /video input not found/) do
      muxer.merge("missing.mp4", "missing.m4a", "out.mp4")
    end
  end

  it "reports a disabled backend" do
    unless ffmpeg_available?
      pending "ffmpeg is not installed"
      next
    end

    with_media_directory do |directory|
      video, audio = generate_inputs(directory)
      muxer = Rill::MediaMuxer.new(Rill::MediaMuxer::Backend::Off)

      expect_raises(Rill::MediaBackendUnavailableError, /disabled/) do
        muxer.merge(video, audio, directory / "out.mp4")
      end
    end
  end
end
