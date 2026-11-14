require "../spec_helper"

describe Rill::Downloader do
  it "downloads to the target and removes the part file" do
    server = TestHTTPServer.new
    server.on("/file") do |_, response|
      body = "hello world"
      response.content_length = body.bytesize
      response.print(body)
    end
    server.start

    begin
      with_temp_dir do |directory|
        target = directory / "file.bin"
        result = downloader.download("#{server.url}/file", target)

        result.should eq(target)
        File.read(target).should eq("hello world")
        File.exists?(Path.new("#{target}.part")).should be_false
        File.exists?(Path.new("#{target}.part.meta")).should be_false
      end
    ensure
      server.close
    end
  end

  it "reports progress" do
    server = TestHTTPServer.new
    server.on("/file") do |_, response|
      body = "hello world"
      response.content_length = body.bytesize
      response.print(body)
    end
    server.start

    begin
      with_temp_dir do |directory|
        events = [] of Rill::DownloadProgress
        downloader.download(
          "#{server.url}/file",
          directory / "file.bin",
          on_progress: ->(progress : Rill::DownloadProgress) { events << progress },
        )

        events.should_not be_empty
        events.last.downloaded_bytes.should eq(11)
        events.last.total_bytes.should eq(11)
        events.last.fraction.should eq(1.0)
      end
    ensure
      server.close
    end
  end

  it "refuses to overwrite an existing target" do
    server = TestHTTPServer.new
    server.on("/file") do |_, response|
      response.content_length = 4
      response.print("new!")
    end
    server.start

    begin
      with_temp_dir do |directory|
        target = directory / "file.bin"
        File.write(target, "old")

        expect_raises(Rill::FileExistsError) do
          downloader.download("#{server.url}/file", target)
        end
        File.read(target).should eq("old")
      end
    ensure
      server.close
    end
  end

  it "overwrites an existing target when asked" do
    server = TestHTTPServer.new
    server.on("/file") do |_, response|
      response.content_length = 4
      response.print("new!")
    end
    server.start

    begin
      with_temp_dir do |directory|
        target = directory / "file.bin"
        File.write(target, "old")

        downloader(overwrite: true).download("#{server.url}/file", target)
        File.read(target).should eq("new!")
      end
    ensure
      server.close
    end
  end

  it "cancels before writing the body" do
    server = TestHTTPServer.new
    server.on("/file") do |_, response|
      response.content_length = 4
      response.print("body")
    end
    server.start

    begin
      with_temp_dir do |directory|
        cancellation = Rill::Cancellation.new
        cancellation.cancel!

        expect_raises(Rill::CancelledError) do
          downloader.download(
            "#{server.url}/file",
            directory / "file.bin",
            cancellation,
          )
        end
        File.exists?(directory / "file.bin").should be_false
      end
    ensure
      server.close
    end
  end

  it "resumes from an existing part file" do
    body = "0123456789"
    ranges = [] of String?
    server_requests = [] of HTTP::Request
    server = TestHTTPServer.new
    server.on("/file") do |request, response|
      range = request.headers["Range"]?
      ranges << range
      server_requests << request

      if range && (match = /bytes=(\d+)-/.match(range))
        serve_range(response, body, match[1].to_i64)
      else
        response.content_length = body.bytesize
        response.print(body)
      end
    end
    server.start

    begin
      with_temp_dir do |directory|
        target = directory / "file.bin"
        File.write(Path.new("#{target}.part"), "0123")
        File.write(
          Path.new("#{target}.part.meta"),
          %({"url":"#{server.url}/file","etag":"v1"}),
        )

        downloader.download("#{server.url}/file", target)

        File.read(target).should eq(body)
        ranges.first.should eq("bytes=4-")
        server_requests.first.headers["If-Range"].should eq("v1")
      end
    ensure
      server.close
    end
  end

  it "restarts when the part file belongs to another URL" do
    body = "0123456789"
    ranges = [] of String?
    server = TestHTTPServer.new
    server.on("/file") do |request, response|
      ranges << request.headers["Range"]?
      response.content_length = body.bytesize
      response.print(body)
    end
    server.start

    begin
      with_temp_dir do |directory|
        target = directory / "file.bin"
        File.write(Path.new("#{target}.part"), "OLD")
        File.write(
          Path.new("#{target}.part.meta"),
          %({"url":"https://example.com/other"}),
        )

        downloader.download("#{server.url}/file", target)

        File.read(target).should eq(body)
        ranges.first.should be_nil
      end
    ensure
      server.close
    end
  end

  it "restarts when the server ignores Range" do
    body = "0123456789"
    server = TestHTTPServer.new
    server.on("/file") do |_, response|
      response.content_length = body.bytesize
      response.print(body)
    end
    server.start

    begin
      with_temp_dir do |directory|
        target = directory / "file.bin"
        File.write(Path.new("#{target}.part"), "XXXX")

        downloader.download("#{server.url}/file", target)

        File.read(target).should eq(body)
      end
    ensure
      server.close
    end
  end

  it "restarts after an invalid Content-Range" do
    body = "0123456789"
    attempts = 0
    server = TestHTTPServer.new
    server.on("/file") do |request, response|
      attempts += 1

      if request.headers["Range"]?
        response.status = :partial_content
        response.headers["Content-Range"] = "bytes 0-3/#{body.bytesize}"
        response.content_length = 6
        response.print(body.byte_slice(4, 6))
      else
        response.content_length = body.bytesize
        response.print(body)
      end
    end
    server.start

    begin
      with_temp_dir do |directory|
        target = directory / "file.bin"
        File.write(Path.new("#{target}.part"), "0123")

        downloader.download("#{server.url}/file", target)

        File.read(target).should eq(body)
        attempts.should eq(2)
      end
    ensure
      server.close
    end
  end

  it "restarts when the requested range is not satisfiable" do
    body = "0123456789"
    attempts = 0
    server = TestHTTPServer.new
    server.on("/file") do |request, response|
      attempts += 1

      if request.headers["Range"]?
        response.status = HTTP::Status.new(416)
        response.content_length = 0
      else
        response.content_length = body.bytesize
        response.print(body)
      end
    end
    server.start

    begin
      with_temp_dir do |directory|
        target = directory / "file.bin"
        File.write(Path.new("#{target}.part"), "0123")

        downloader.download("#{server.url}/file", target)

        File.read(target).should eq(body)
        attempts.should eq(2)
      end
    ensure
      server.close
    end
  end

  it "retries an interrupted body with a Range request" do
    body = "0123456789"
    attempts = 0
    server = TestHTTPServer.new
    server.on("/file") do |request, response|
      attempts += 1

      if range = request.headers["Range"]?
        offset = /bytes=(\d+)-/.match(range).not_nil![1].to_i64
        serve_range(response, body, offset)
      else
        response.content_length = body.bytesize
        response.print(body.byte_slice(0, 4))
        response.close
      end
    end
    server.start

    begin
      with_temp_dir do |directory|
        target = directory / "file.bin"

        downloader.download("#{server.url}/file", target)

        File.read(target).should eq(body)
        attempts.should eq(2)
      end
    ensure
      server.close
    end
  end

  it "retries server errors before writing" do
    attempts = 0
    server = TestHTTPServer.new
    server.on("/file") do |_, response|
      attempts += 1

      if attempts == 1
        response.status = :internal_server_error
        response.content_length = 4
        response.print("fail")
      else
        response.content_length = 4
        response.print("body")
      end
    end
    server.start

    begin
      with_temp_dir do |directory|
        target = directory / "file.bin"

        downloader.download("#{server.url}/file", target)

        File.read(target).should eq("body")
        attempts.should eq(2)
      end
    ensure
      server.close
    end
  end

  it "downloads and merges a split video and audio plan" do
    unless Process.run(
             "ffmpeg",
             ["-version"],
             output: Process::Redirect::Close,
             error: Process::Redirect::Close,
           ).success?
      pending "ffmpeg is not installed"
      next
    end

    with_temp_dir do |directory|
      video_path = directory / "input.mp4"
      audio_path = directory / "input.m4a"

      Process.run(
        "ffmpeg",
        [
          "-hide_banner", "-loglevel", "error", "-y",
          "-f", "lavfi", "-i", "color=c=black:s=160x120:d=1",
          "-an", "-c:v", "mpeg4", video_path.to_s,
        ],
        output: Process::Redirect::Close,
        error: Process::Redirect::Close,
      ).success?.should be_true

      Process.run(
        "ffmpeg",
        [
          "-hide_banner", "-loglevel", "error", "-y",
          "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
          "-vn", "-c:a", "aac", audio_path.to_s,
        ],
        output: Process::Redirect::Close,
        error: Process::Redirect::Close,
      ).success?.should be_true

      video_bytes = File.read(video_path)
      audio_bytes = File.read(audio_path)

      server = TestHTTPServer.new
      server.on("/video.mp4") do |_, response|
        response.content_length = video_bytes.bytesize
        response.print(video_bytes)
      end
      server.on("/audio.m4a") do |_, response|
        response.content_length = audio_bytes.bytesize
        response.print(audio_bytes)
      end
      server.start

      begin
        target = directory / "merged.mp4"
        video = Rill::Format.new(
          format_id: "video",
          url: URI.parse("#{server.url}/video.mp4"),
          kind: Rill::FormatKind::Video,
          container: "mp4",
          filesize: video_bytes.bytesize.to_i64,
        )
        audio = Rill::Format.new(
          format_id: "audio",
          url: URI.parse("#{server.url}/audio.m4a"),
          kind: Rill::FormatKind::Audio,
          container: "mp4",
          filesize: audio_bytes.bytesize.to_i64,
        )
        plan = Rill::DownloadPlan.new(video, audio)

        downloader.download(plan, target)

        File.size(target).should be > 0
        File.exists?(Path.new("#{target}.video")).should be_false
        File.exists?(Path.new("#{target}.audio")).should be_false
      ensure
        server.close
      end
    end
  end

  it "downloads range-chunked formats in fixed windows" do
    body = "x" * 2_500_000
    ranges = [] of String

    server = TestHTTPServer.new
    server.on("/file") do |request, response|
      range = request.headers["Range"]?.not_nil!
      ranges << range
      match = /bytes=(\d+)-(\d+)/.match(range).not_nil!
      start = match[1].to_i64
      finish = match[2].to_i64

      response.status = :partial_content
      response.headers["Content-Range"] = "bytes #{start}-#{finish}/#{body.bytesize}"
      response.content_length = finish - start + 1
      response.print(body.byte_slice(start, finish - start + 1))
    end
    server.start

    begin
      with_temp_dir do |directory|
        target = directory / "file.bin"
        format = Rill::Format.new(
          format_id: "file",
          url: URI.parse("#{server.url}/file"),
          filesize: body.bytesize.to_i64,
          range_chunk_size: 1024_i64 * 1024,
        )

        downloader.download(format, target)

        File.read(target).should eq(body)
        ranges.should eq([
          "bytes=0-1048575",
          "bytes=1048576-2097151",
          "bytes=2097152-2499999",
        ])
      end
    ensure
      server.close
    end
  end

  it "rejects a malformed partial response" do
    server = TestHTTPServer.new
    server.on("/file") do |_, response|
      response.status = :partial_content
      response.headers["Content-Range"] = "bytes 5-9/10"
      response.content_length = 5
      response.print("01234")
    end
    server.start

    begin
      with_temp_dir do |directory|
        target = directory / "file.bin"

        expect_raises(Rill::ResumeError, /Content-Range/) do
          downloader.download("#{server.url}/file", target)
        end
        File.exists?(target).should be_false
      end
    ensure
      server.close
    end
  end

  it "refuses a symlinked part file" do
    server = TestHTTPServer.new
    server.on("/file") do |_, response|
      response.content_length = 4
      response.print("body")
    end
    server.start

    begin
      with_temp_dir do |directory|
        target = directory / "file.bin"
        victim = directory / "victim.txt"
        File.write(victim, "keep")
        File.symlink(victim, Path.new("#{target}.part"))

        expect_raises(Rill::DownloadError, /symlink/) do
          downloader.download("#{server.url}/file", target)
        end
        File.read(victim).should eq("keep")
      end
    ensure
      server.close
    end
  end

  it "accepts a body without a Content-Length" do
    server = TestHTTPServer.new
    server.on("/file") { |_, response| response.print("chunked") }
    server.start

    begin
      with_temp_dir do |directory|
        target = directory / "file.bin"

        downloader.download("#{server.url}/file", target)

        File.read(target).should eq("chunked")
      end
    ensure
      server.close
    end
  end
end
