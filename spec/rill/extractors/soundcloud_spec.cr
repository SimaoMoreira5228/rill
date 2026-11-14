require "../../spec_helper"

private def soundcloud_track_path : String
  "/forss/flickermood"
end

private def soundcloud_set_path : String
  "/dawning_records/sets/ibiza-summer-mix-2026-lounge"
end

private def soundcloud_transcoding_path : String
  "/media/soundcloud:tracks:293/fixture-aac-160/stream/hls"
end

private def soundcloud_hls_url(server : TestHTTPServer) : String
  "#{server.url}/hls/293/playlist.m3u8"
end

private def soundcloud_page(server : TestHTTPServer) : String
  fixture("soundcloud", "track.html").gsub(
    "https://api-v2.soundcloud.com",
    server.url,
  )
end

private def serve_soundcloud_track(server : TestHTTPServer) : Nil
  server.on(soundcloud_track_path) do |_, response|
    response.content_type = "text/html"
    response.print(soundcloud_page(server))
  end
end

private def serve_soundcloud_set(server : TestHTTPServer) : Nil
  server.on(soundcloud_set_path) do |_, response|
    response.content_type = "text/html"
    response.print(fixture("soundcloud", "set.html"))
  end
end

private def serve_soundcloud_stream(server : TestHTTPServer) : Nil
  server.on(soundcloud_transcoding_path) do |_, response|
    response.content_type = "application/json"
    response.print(%({"url":"#{soundcloud_hls_url(server)}"}))
  end
end

describe Rill::Extractors::SoundCloud do
  it "matches track and short-link URLs" do
    extractor = Rill::Extractors::SoundCloud.new

    extractor.matches?(URI.parse("https://soundcloud.com/forss/flickermood")).should be_true
    extractor.matches?(URI.parse("http://soundcloud.com/forss/flickermood")).should be_true
    extractor.matches?(URI.parse("https://www.soundcloud.com/forss/flickermood/")).should be_true
    extractor.matches?(URI.parse("https://soundcloud.com/forss/flickermood?si=abc")).should be_true
    extractor.matches?(URI.parse("https://soundcloud.com/dawning_records/sets/ibiza-summer-mix-2026-lounge")).should be_true
    extractor.matches?(URI.parse("https://www.soundcloud.com/dawning_records/sets/ibiza-summer-mix-2026-lounge/")).should be_true
    extractor.matches?(URI.parse("https://on.soundcloud.com/abc123")).should be_true
    extractor.matches?(URI.parse("https://on.soundcloud.com/abc123/")).should be_true
  end

  it "rejects collection pages, user pages, and other hosts" do
    extractor = Rill::Extractors::SoundCloud.new

    extractor.matches?(URI.parse("https://soundcloud.com/forss/albums/flickermood")).should be_false
    extractor.matches?(URI.parse("https://soundcloud.com/forss/playlists/flickermood")).should be_false
    extractor.matches?(URI.parse("https://soundcloud.com/forss/tracks")).should be_false
    extractor.matches?(URI.parse("https://soundcloud.com/forss")).should be_false
    extractor.matches?(URI.parse("https://soundcloud.com/sets/flickermood")).should be_false
    extractor.matches?(URI.parse("https://m.soundcloud.com/forss/flickermood")).should be_false
    extractor.matches?(URI.parse("https://api-v2.soundcloud.com/forss/flickermood")).should be_false
    extractor.matches?(URI.parse("https://example.com/forss/flickermood")).should be_false
    extractor.matches?(URI.parse("https://on.soundcloud.com/abc/extra")).should be_false
    extractor.matches?(URI.parse("ftp://soundcloud.com/forss/flickermood")).should be_false
  end

  it "extracts a track and resolves the best HLS stream" do
    server = TestHTTPServer.new
    serve_soundcloud_track(server)
    serve_soundcloud_stream(server)
    server.start

    begin
      media = Rill::Extractors::SoundCloud.new.extract(
        URI.parse("#{server.url}#{soundcloud_track_path}"),
        Rill::HTTPClient.new,
      ).as(Rill::Media)
      media.validate!

      media.id.should eq("293")
      media.title.should eq("Flickermood")
      media.description.should eq("From the Soulhack album")
      media.uploader.should eq("Forss")
      media.duration_seconds.not_nil!.should be_close(213.886, 0.001)
      media.upload_date.should eq("2007-09-22")
      media.thumbnail_url.not_nil!.to_s.should eq(
        "https://i1.sndcdn.com/artworks-000067273316-smsiqx-t500x500.jpg",
      )
      media.extractor.should eq("soundcloud")
      media.formats.size.should eq(1)

      format = media.formats.first
      format.format_id.should eq("hls-aac_160k")
      format.kind.should eq(Rill::FormatKind::Audio)
      format.protocol.should eq(Rill::FormatProtocol::Hls)
      format.container.should eq("m4a")
      format.bitrate.should eq(160_000_i64)
      format.url.to_s.should eq(soundcloud_hls_url(server))

      request = server.requests.find { |item| item.path == soundcloud_transcoding_path }
      request = request.not_nil!
      request.query_params["client_id"].should eq("fixture-client-id")
      request.query_params["track_authorization"].should eq("fixture-track-authorization")
    ensure
      server.close
    end
  end

  it "follows short-link redirects and parses the final URL" do
    server = TestHTTPServer.new
    server.on("/abc123") do |_, response|
      response.status = HTTP::Status::FOUND
      response.headers["Location"] = soundcloud_track_path
    end
    serve_soundcloud_track(server)
    serve_soundcloud_stream(server)
    server.start

    begin
      media = Rill::Extractors::SoundCloud.new.extract(
        URI.parse("#{server.url}/abc123"),
        Rill::HTTPClient.new,
      ).as(Rill::Media)

      media.webpage_url.to_s.should eq("#{server.url}#{soundcloud_track_path}")
      media.title.should eq("Flickermood")
    ensure
      server.close
    end
  end

  it "extracts a set as a playlist with ordered entries" do
    server = TestHTTPServer.new
    serve_soundcloud_set(server)
    server.start

    begin
      playlist = Rill::Extractors::SoundCloud.new.extract(
        URI.parse("#{server.url}#{soundcloud_set_path}"),
        Rill::HTTPClient.new,
      ).as(Rill::Playlist)
      playlist.validate!

      playlist.id.should eq("2220415994")
      playlist.title.should eq(
        "Summer Chill Mix 2026 🌞🌴 Lounge Music, Chillout Music & Ibiza Deep House",
      )
      playlist.description.not_nil!.should start_with("Soak up the sunshine with Summer Chill Mix 2026")
      playlist.webpage_url.to_s.should eq("#{server.url}#{soundcloud_set_path}")
      playlist.extractor.should eq("soundcloud")
      playlist.entries.map(&.url.to_s).should eq([
        "https://soundcloud.com/lo-freq-1/sweet-disposition-a-moment-a",
        "https://soundcloud.com/dawning_records/sur-faire-clover-place-we-know",
        "https://soundcloud.com/7cultrecords/oskar-med-k-make-me-feel",
      ])
      playlist.entries.first.title.should eq("Sweet Disposition (a moment, a love)")
      playlist.entries.first.id.should eq("2094981591")
      server.requests.size.should eq(1)
    ensure
      server.close
    end
  end

  it "follows short-link redirects to a set" do
    server = TestHTTPServer.new
    server.on("/set123") do |_, response|
      response.status = HTTP::Status::FOUND
      response.headers["Location"] = soundcloud_set_path
    end
    serve_soundcloud_set(server)
    server.start

    begin
      playlist = Rill::Extractors::SoundCloud.new.extract(
        URI.parse("#{server.url}/set123"),
        Rill::HTTPClient.new,
      ).as(Rill::Playlist)

      playlist.webpage_url.to_s.should eq("#{server.url}#{soundcloud_set_path}")
      playlist.entries.size.should eq(3)
    ensure
      server.close
    end
  end

  it "reports sets without tracks as unavailable" do
    body = <<-HTML
      <script>window.__sc_hydration = [
        {"hydratable": "apiClient", "data": {"id": "fixture-client-id"}},
        {
          "hydratable": "playlist",
          "data": {"id": 1, "title": "Empty", "tracks": []}
        }
      ];</script>
      HTML

    server = TestHTTPServer.new
    server.on(soundcloud_set_path) { |_, response| response.print(body) }
    server.start

    begin
      extractor = Rill::Extractors::SoundCloud.new
      expect_raises(Rill::MediaUnavailableError, /no tracks/) do
        extractor.extract(
          URI.parse("#{server.url}#{soundcloud_set_path}"),
          Rill::HTTPClient.new,
        )
      end
    ensure
      server.close
    end
  end

  it "prefers a progressive transcoding over HLS" do
    body = <<-HTML
      <script>window.__sc_hydration = [
        {
          "hydratable": "apiClient",
          "data": {"id": "fixture-client-id"}
        },
        {
          "hydratable": "sound",
          "data": {
            "id": 1,
            "title": "Progressive",
            "duration": 1000,
            "track_authorization": "fixture-track-authorization",
            "media": {
              "transcodings": [
                {
                  "url": "https://api-v2.soundcloud.com/media/1/stream/progressive",
                  "preset": "mp3_128",
                  "format": {"protocol": "progressive", "mime_type": "audio/mpeg"}
                }
              ]
            }
          }
        }
      ];</script>
      HTML

    server = TestHTTPServer.new
    server.on(soundcloud_track_path) { |_, response| response.print(body) }
    server.start

    begin
      media = Rill::Extractors::SoundCloud.new.extract(
        URI.parse("#{server.url}#{soundcloud_track_path}"),
        Rill::HTTPClient.new,
      ).as(Rill::Media)
      media.validate!

      format = media.formats.first
      format.format_id.should eq("progressive-mp3_128")
      format.kind.should eq(Rill::FormatKind::Audio)
      format.protocol.should eq(Rill::FormatProtocol::Http)
      format.container.should eq("mp3")
      format.bitrate.should eq(128_000_i64)
      format.url.to_s.should eq(
        "https://api-v2.soundcloud.com/media/1/stream/progressive",
      )
    ensure
      server.close
    end
  end

  it "reports tracks without transcodings as unavailable" do
    body = <<-HTML
      <script>window.__sc_hydration = [
        {"hydratable": "apiClient", "data": {"id": "fixture-client-id"}},
        {
          "hydratable": "sound",
          "data": {"id": 1, "title": "Empty", "media": {"transcodings": []}}
        }
      ];</script>
      HTML

    server = TestHTTPServer.new
    server.on(soundcloud_track_path) { |_, response| response.print(body) }
    server.start

    begin
      extractor = Rill::Extractors::SoundCloud.new
      expect_raises(Rill::MediaUnavailableError, /transcodings/) do
        extractor.extract(
          URI.parse("#{server.url}#{soundcloud_track_path}"),
          Rill::HTTPClient.new,
        )
      end
    ensure
      server.close
    end
  end
end
