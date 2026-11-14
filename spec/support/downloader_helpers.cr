require "file_utils"

module DownloaderSpecHelpers
  def with_temp_dir(&)
    directory = File.join(Dir.tempdir, "rill-spec-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(directory)

    begin
      yield Path.new(directory)
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  def downloader(
    retries : Int32 = 2,
    resume : Bool = true,
    overwrite : Bool = false,
    media_muxer : Rill::MediaMuxer = Rill::MediaMuxer.new(Rill::MediaMuxer::Backend::System),
  ) : Rill::Downloader
    options = Rill::RequestOptions.new
    options.retries = retries
    options.retry_delay = Time::Span.zero
    options.read_timeout = 1.second
    Rill::Downloader.new(
      options,
      resume: resume,
      overwrite: overwrite,
      media_muxer: media_muxer,
    )
  end

  def serve_range(response : HTTP::Server::Response, body : String, offset : Int64) : Nil
    response.status = :partial_content
    response.headers["Content-Range"] = "bytes #{offset}-#{body.bytesize - 1}/#{body.bytesize}"
    response.content_length = body.bytesize - offset
    response.print(body.byte_slice(offset, body.bytesize - offset))
  end
end

include DownloaderSpecHelpers
