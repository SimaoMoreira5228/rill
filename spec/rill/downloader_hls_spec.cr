require "../spec_helper"

private def hls_format(url : String) : Rill::Format
  Rill::Format.new(
    format_id: "hls",
    url: URI.parse(url),
    protocol: Rill::FormatProtocol::Hls,
  )
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
end
