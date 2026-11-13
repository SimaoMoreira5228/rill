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
    server = TestHTTPServer.new
    server.on("/file") do |request, response|
      range = request.headers["Range"]?
      ranges << range

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

        downloader.download("#{server.url}/file", target)

        File.read(target).should eq(body)
        ranges.first.should eq("bytes=4-")
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
