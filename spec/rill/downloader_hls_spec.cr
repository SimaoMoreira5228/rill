require "../spec_helper"

private def hls_format(url : String) : Rill::Format
  Rill::Format.new(
    format_id: "hls",
    url: URI.parse(url),
    protocol: Rill::FormatProtocol::Hls,
  )
end

private def hls_audio_ffmpeg_available? : Bool
  Process.run(
    "ffmpeg",
    ["-version"],
    output: Process::Redirect::Close,
    error: Process::Redirect::Close,
  ).success?
rescue File::Error
  false
end

private def hls_audio_generate(directory : Path) : Bool
  video = directory / "video"
  audio = directory / "audio"
  Dir.mkdir_p(video)
  Dir.mkdir_p(audio)

  video_ok = Process.run(
    "ffmpeg",
    [
      "-hide_banner", "-loglevel", "error", "-y",
      "-f", "lavfi", "-i", "color=c=black:s=160x120:d=2",
      "-an", "-c:v", "mpeg4", "-g", "25",
      "-f", "hls", "-hls_time", "1", "-hls_playlist_type", "vod",
      "-hls_segment_type", "fmp4",
      "-hls_fmp4_init_filename", "init.mp4",
      "-hls_segment_filename", (video / "v%03d.m4s").to_s,
      (video / "video.m3u8").to_s,
    ],
    output: Process::Redirect::Close,
    error: Process::Redirect::Close,
  ).success?

  audio_ok = Process.run(
    "ffmpeg",
    [
      "-hide_banner", "-loglevel", "error", "-y",
      "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
      "-vn", "-c:a", "aac",
      "-f", "hls", "-hls_time", "1", "-hls_playlist_type", "vod",
      "-hls_segment_type", "fmp4",
      "-hls_fmp4_init_filename", "init.mp4",
      "-hls_segment_filename", (audio / "a%03d.m4s").to_s,
      (audio / "audio.m3u8").to_s,
    ],
    output: Process::Redirect::Close,
    error: Process::Redirect::Close,
  ).success?

  video_ok && audio_ok
end

private def hls_audio_serve(server : TestHTTPServer, prefix : String, directory : Path) : Nil
  Dir.each_child(directory) do |name|
    path = directory / name
    next unless File.file?(path)

    body = File.read(path)
    content_type = File.extname(name) == ".m3u8" ? "application/vnd.apple.mpegurl" : "video/mp4"

    server.on("#{prefix}/#{name}") do |_, response|
      response.content_type = content_type
      response.print(body)
    end
  end
end

describe Rill::Downloader do
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

  it "merges HLS video with separate audio" do
    unless hls_audio_ffmpeg_available?
      pending! "ffmpeg is not installed"
    end

    with_temp_dir do |directory|
      source = directory / "source"
      Dir.mkdir_p(source)
      hls_audio_generate(source).should be_true

      server = TestHTTPServer.new
      hls_audio_serve(server, "/video", source / "video")
      hls_audio_serve(server, "/audio", source / "audio")
      server.start

      begin
        video = Rill::Format.new(
          format_id: "video",
          url: URI.parse("#{server.url}/video/video.m3u8"),
          kind: Rill::FormatKind::Video,
          protocol: Rill::FormatProtocol::Hls,
          container: "mp4",
        )
        audio = Rill::Format.new(
          format_id: "audio",
          url: URI.parse("#{server.url}/audio/audio.m3u8"),
          kind: Rill::FormatKind::Audio,
          protocol: Rill::FormatProtocol::Hls,
          container: "mp4",
        )
        target = directory / "merged.mp4"

        downloader.download(Rill::DownloadPlan.new(video, audio), target)

        File.size(target).should be > 0
        File.exists?(Path.new("#{target}.video")).should be_false
        File.exists?(Path.new("#{target}.audio")).should be_false
      ensure
        server.close
      end
    end
  end

  it "downloads a live HLS playlist from the live edge until it ends" do
    server = TestHTTPServer.new
    requests = 0
    server.on("/hls/media.m3u8") do |_, response|
      requests += 1
      response.content_type = "application/vnd.apple.mpegurl"
      response.print(case requests
      when 1
        "#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nseg0.ts\n#EXTINF:1,\nseg1.ts\n"
      when 2
        "#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nseg0.ts\n#EXTINF:1,\nseg1.ts\n#EXTINF:1,\nseg2.ts\n"
      else
        "#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nseg0.ts\n#EXTINF:1,\nseg1.ts\n#EXTINF:1,\nseg2.ts\n#EXTINF:1,\nseg3.ts\n#EXT-X-ENDLIST\n"
      end)
    end
    {"seg0.ts" => "AAAA", "seg1.ts" => "BBBB", "seg2.ts" => "CCCC", "seg3.ts" => "DDDD"}.each do |name, body|
      server.on("/hls/#{name}") do |_, response|
        response.content_length = body.bytesize
        response.print(body)
      end
    end
    server.start

    begin
      with_temp_dir do |directory|
        target = directory / "media.ts"

        downloader.download(hls_format("#{server.url}/hls/media.m3u8"), target)

        File.read(target).should eq("BBBBCCCCDDDD")
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
  it "rejects an unverified segment extension" do
    server = TestHTTPServer.new
    server.on("/hls/media.m3u8") do |_, response|
      response.print("#EXTM3U\n#EXTINF:4,\nseg.bin\n#EXT-X-ENDLIST\n")
    end
    server.start

    begin
      with_temp_dir do |directory|
        target = directory / "media.bin"

        expect_raises(Rill::UnsupportedManifestError, /not verified/) do
          downloader.download(hls_format("#{server.url}/hls/media.m3u8"), target)
        end
        File.exists?(target).should be_false
        server.requests.size.should eq(1)
      end
    ensure
      server.close
    end
  end

  it "requires an init section for fragmented MP4 segments" do
    server = TestHTTPServer.new
    server.on("/hls/media.m3u8") do |_, response|
      response.print("#EXTM3U\n#EXTINF:4,\nseg.m4s\n#EXT-X-ENDLIST\n")
    end
    server.start

    begin
      with_temp_dir do |directory|
        target = directory / "media.mp4"

        expect_raises(Rill::UnsupportedManifestError, /not verified/) do
          downloader.download(hls_format("#{server.url}/hls/media.m3u8"), target)
        end
      end
    ensure
      server.close
    end
  end

  it "rejects a map with transport stream segments" do
    server = TestHTTPServer.new
    server.on("/hls/media.m3u8") do |_, response|
      response.print("#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:4,\nseg.ts\n#EXT-X-ENDLIST\n")
    end
    server.start

    begin
      with_temp_dir do |directory|
        target = directory / "media.ts"

        expect_raises(Rill::UnsupportedManifestError, /fragmented MP4 layout/) do
          downloader.download(hls_format("#{server.url}/hls/media.m3u8"), target)
        end
      end
    ensure
      server.close
    end
  end
end
