require "file_utils"

require "../spec_helper"

private def with_temp_dir(&)
  directory = File.join(Dir.tempdir, "rill-spec-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(directory)

  begin
    yield Path.new(directory)
  ensure
    FileUtils.rm_rf(directory)
  end
end

private def downloader(
  retries : Int32 = 2,
  resume : Bool = true,
  overwrite : Bool = false,
) : Rill::Downloader
  options = Rill::RequestOptions.new
  options.retries = retries
  options.retry_delay = Time::Span.zero
  options.read_timeout = 1.second
  Rill::Downloader.new(options, resume: resume, overwrite: overwrite)
end

private def hls_format(url : String) : Rill::Format
  Rill::Format.new(
    format_id: "hls",
    url: URI.parse(url),
    protocol: Rill::FormatProtocol::Hls,
  )
end

private def serve_range(response : HTTP::Server::Response, body : String, offset : Int64) : Nil
  response.status = :partial_content
  response.headers["Content-Range"] = "bytes #{offset}-#{body.bytesize - 1}/#{body.bytesize}"
  response.content_length = body.bytesize - offset
  response.print(body.byte_slice(offset, body.bytesize - offset))
end

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

  it "downloads HLS segments in order" do
    server = TestHTTPServer.new
    server.on("/hls/media.m3u8") do |_, response|
      response.print(<<-M3U8)
        #EXTM3U
        #EXTINF:4,
        seg0.ts
        #EXTINF:4,
        seg1.ts
        #EXT-X-ENDLIST
      M3U8
    end
    server.on("/hls/seg0.ts") do |_, response|
      response.content_length = 4
      response.print("AAAA")
    end
    server.on("/hls/seg1.ts") do |_, response|
      response.content_length = 4
      response.print("BBBB")
    end
    server.start

    begin
      with_temp_dir do |directory|
        target = directory / "media.ts"

        downloader.download(hls_format("#{server.url}/hls/media.m3u8"), target)

        File.read(target).should eq("AAAABBBB")
      end
    ensure
      server.close
    end
  end

  it "downloads an HLS init section before media segments" do
    server = TestHTTPServer.new
    server.on("/hls/media.m3u8") do |_, response|
      response.print(<<-M3U8)
        #EXTM3U
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:4,
        seg.m4s
        #EXT-X-ENDLIST
      M3U8
    end
    server.on("/hls/init.mp4") do |_, response|
      response.content_length = 4
      response.print("INIT")
    end
    server.on("/hls/seg.m4s") do |_, response|
      response.content_length = 4
      response.print("DATA")
    end
    server.start

    begin
      with_temp_dir do |directory|
        target = directory / "media.mp4"

        downloader.download(hls_format("#{server.url}/hls/media.m3u8"), target)

        File.read(target).should eq("INITDATA")
      end
    ensure
      server.close
    end
  end

  it "rejects live HLS playlists" do
    server = TestHTTPServer.new
    server.on("/hls/media.m3u8") do |_, response|
      response.print("#EXTM3U\n#EXTINF:4,\nseg.ts\n")
    end
    server.start

    begin
      with_temp_dir do |directory|
        target = directory / "media.ts"

        expect_raises(Rill::UnsupportedManifestError, /live HLS/) do
          downloader.download(hls_format("#{server.url}/hls/media.m3u8"), target)
        end
        File.exists?(target).should be_false
        File.exists?(Path.new("#{target}.part")).should be_false
      end
    ensure
      server.close
    end
  end

  it "rejects encrypted HLS playlists" do
    server = TestHTTPServer.new
    server.on("/hls/media.m3u8") do |_, response|
      response.print(<<-M3U8)
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        #EXTINF:4,
        seg.ts
        #EXT-X-ENDLIST
      M3U8
    end
    server.start

    begin
      with_temp_dir do |directory|
        target = directory / "media.ts"

        expect_raises(Rill::UnsupportedManifestError, /encrypted HLS/) do
          downloader.download(hls_format("#{server.url}/hls/media.m3u8"), target)
        end
      end
    ensure
      server.close
    end
  end

  it "rejects byte-range HLS segments" do
    server = TestHTTPServer.new
    server.on("/hls/media.m3u8") do |_, response|
      response.print(<<-M3U8)
        #EXTM3U
        #EXTINF:4,
        #EXT-X-BYTERANGE:100@0
        seg.ts
        #EXT-X-ENDLIST
      M3U8
    end
    server.start

    begin
      with_temp_dir do |directory|
        target = directory / "media.ts"

        expect_raises(Rill::UnsupportedManifestError, /byte ranges/) do
          downloader.download(hls_format("#{server.url}/hls/media.m3u8"), target)
        end
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

  it "fails instead of silently truncating an HLS segment" do
    server = TestHTTPServer.new
    server.on("/hls/media.m3u8") do |_, response|
      response.print("#EXTM3U\n#EXTINF:4,\nseg.ts\n#EXT-X-ENDLIST\n")
    end
    server.on("/hls/seg.ts") do |_, response|
      response.content_length = 10
      response.print("0123")
      response.close
    end
    server.start

    begin
      with_temp_dir do |directory|
        target = directory / "media.ts"

        expect_raises(Rill::Error) do
          downloader.download(hls_format("#{server.url}/hls/media.m3u8"), target)
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
