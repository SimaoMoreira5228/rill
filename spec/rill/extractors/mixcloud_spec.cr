require "../../spec_helper"

private def mixcloud_path : String
  "/dholbach/cryptkeeper"
end

private def mixcloud_cloudcast(body : String) : Hash(String, JSON::Any)
  payload = JSON.parse(body).as_h
  payload["data"].as_h["cloudcastLookup"].as_h
end

private def serve_mixcloud(server : TestHTTPServer, body : String) : Nil
  server.on("/graphql") do |_, response|
    response.content_type = "application/json"
    response.print(body)
  end
end

private def serve_mixcloud(server : TestHTTPServer) : Nil
  serve_mixcloud(server, fixture("mixcloud", "cloudcast.json"))
end

describe Rill::Extractors::Mixcloud do
  it "matches cloudcast URLs" do
    extractor = Rill::Extractors::Mixcloud.new

    extractor.matches?(URI.parse("https://www.mixcloud.com/dholbach/cryptkeeper")).should be_true
    extractor.matches?(URI.parse("http://mixcloud.com/dholbach/cryptkeeper")).should be_true
    extractor.matches?(URI.parse("https://beta.mixcloud.com/dholbach/cryptkeeper/")).should be_true
    extractor.matches?(URI.parse("https://m.mixcloud.com/dholbach/cryptkeeper?si=abc")).should be_true
  end

  it "rejects user pages, reserved slugs, and other hosts" do
    extractor = Rill::Extractors::Mixcloud.new

    extractor.matches?(URI.parse("https://www.mixcloud.com/dholbach")).should be_false
    extractor.matches?(URI.parse("https://www.mixcloud.com/dholbach/")).should be_false

    %w(stream uploads favorites listens playlists).each do |slug|
      extractor.matches?(URI.parse("https://www.mixcloud.com/dholbach/#{slug}")).should be_false
    end

    extractor.matches?(URI.parse("https://www.mixcloud.com/dholbach/cryptkeeper/extra")).should be_false
    extractor.matches?(URI.parse("https://app.mixcloud.com/dholbach/cryptkeeper")).should be_false
    extractor.matches?(URI.parse("https://example.com/dholbach/cryptkeeper")).should be_false
    extractor.matches?(URI.parse("ftp://www.mixcloud.com/dholbach/cryptkeeper")).should be_false
  end

  it "extracts metadata and the decrypted progressive stream" do
    server = TestHTTPServer.new
    serve_mixcloud(server)
    server.start

    begin
      extractor = Rill::Extractors::Mixcloud.new(server.url)
      media = extractor.extract(
        URI.parse("#{server.url}#{mixcloud_path}"),
        Rill::HTTPClient.new,
      ).as(Rill::Media)
      media.validate!

      media.id.should eq("dholbach_cryptkeeper")
      media.title.should eq("Cryptkeeper")
      media.description.should eq(
        "After quite a long silence from myself, finally another Drum'n'Bass mix with " \
        "my favourite current dance floor bangers.",
      )
      media.uploader.should eq("dholbach")
      media.duration_seconds.not_nil!.should be_close(3723.0, 0.001)
      media.upload_date.should eq("2011-11-15")
      media.thumbnail_url.not_nil!.to_s.should eq(
        "https://thumbnailer.mixcloud.com/unsafe/1024x1024/extaudio/a/4/1/3/" \
        "7e83-445a-4339-9f12-677a718db4de.jpg",
      )
      media.extractor.should eq("mixcloud")
      media.formats.size.should eq(1)

      format = media.formats.first
      format.format_id.should eq("progressive")
      format.kind.should eq(Rill::FormatKind::Audio)
      format.protocol.should eq(Rill::FormatProtocol::Http)
      format.container.should eq("m4a")
      format.url.to_s.should eq(
        "https://dl.mixcloud.com/secure/c/m4a/64/6/f/c/d/" \
        "d610-b93d-40e5-9086-d731038019d9.m4a?sig=ZoVzO9AXXMDKP4gxB6y3uQ",
      )

      request = server.requests.find { |item| item.path == "/graphql" }
      query = request.not_nil!.query_params["query"]
      query.should contain("cloudcastLookup")
      query.should contain(%(username: "dholbach"))
      query.should contain(%(slug: "cryptkeeper"))
    ensure
      server.close
    end
  end

  it "falls back to the decrypted HLS stream" do
    payload = JSON.parse(fixture("mixcloud", "cloudcast.json")).as_h
    cloudcast = payload["data"].as_h["cloudcastLookup"].as_h
    cloudcast["streamInfo"].as_h.delete("url")

    server = TestHTTPServer.new
    serve_mixcloud(server, payload.to_json)
    server.start

    begin
      extractor = Rill::Extractors::Mixcloud.new(server.url)
      media = extractor.extract(
        URI.parse("#{server.url}#{mixcloud_path}"),
        Rill::HTTPClient.new,
      ).as(Rill::Media)
      media.validate!

      format = media.formats.first
      format.format_id.should eq("hls")
      format.kind.should eq(Rill::FormatKind::Audio)
      format.protocol.should eq(Rill::FormatProtocol::Hls)
      format.container.should eq("m4a")
      format.url.to_s.should eq(
        "https://aod.mixcloud.com/secure/hls/6/f/c/d/" \
        "d610-b93d-40e5-9086-d731038019d9.m4a/index.m3u8",
      )
    ensure
      server.close
    end
  end

  it "falls back to the decrypted DASH stream" do
    payload = JSON.parse(fixture("mixcloud", "cloudcast.json")).as_h
    cloudcast = payload["data"].as_h["cloudcastLookup"].as_h
    stream_info = cloudcast["streamInfo"].as_h
    stream_info.delete("url")
    stream_info.delete("hlsUrl")

    server = TestHTTPServer.new
    serve_mixcloud(server, payload.to_json)
    server.start

    begin
      extractor = Rill::Extractors::Mixcloud.new(server.url)
      media = extractor.extract(
        URI.parse("#{server.url}#{mixcloud_path}"),
        Rill::HTTPClient.new,
      ).as(Rill::Media)
      media.validate!

      format = media.formats.first
      format.format_id.should eq("dash")
      format.protocol.should eq(Rill::FormatProtocol::Dash)
      format.container.should eq("m4a")
      format.url.to_s.should eq(
        "https://aod.mixcloud.com/secure/dash2/6/f/c/d/" \
        "d610-b93d-40e5-9086-d731038019d9.m4a/manifest.mpd",
      )
    ensure
      server.close
    end
  end

  it "reports restricted cloudcasts as unavailable" do
    cases = {
      "tracklist"   => /licensing restrictions/,
      "repeat_play" => /play limit/,
      "geo_block"   => /track is restricted/,
    }

    cases.each do |reason, pattern|
      payload = JSON.parse(fixture("mixcloud", "cloudcast.json")).as_h
      cloudcast = payload["data"].as_h["cloudcastLookup"].as_h
      cloudcast["restrictedReason"] = JSON::Any.new(reason)

      server = TestHTTPServer.new
      serve_mixcloud(server, payload.to_json)
      server.start

      begin
        extractor = Rill::Extractors::Mixcloud.new(server.url)
        expect_raises(Rill::MediaUnavailableError, pattern) do
          extractor.extract(
            URI.parse("#{server.url}#{mixcloud_path}"),
            Rill::HTTPClient.new,
          )
        end
      ensure
        server.close
      end
    end
  end

  it "reports cloudcasts without a playable stream as unavailable" do
    payload = JSON.parse(fixture("mixcloud", "cloudcast.json")).as_h
    cloudcast = payload["data"].as_h["cloudcastLookup"].as_h
    stream_info = cloudcast["streamInfo"].as_h
    stream_info.delete("url")
    stream_info.delete("hlsUrl")
    stream_info.delete("dashUrl")

    server = TestHTTPServer.new
    serve_mixcloud(server, payload.to_json)
    server.start

    begin
      extractor = Rill::Extractors::Mixcloud.new(server.url)
      expect_raises(Rill::MediaUnavailableError, /no playable stream/) do
        extractor.extract(
          URI.parse("#{server.url}#{mixcloud_path}"),
          Rill::HTTPClient.new,
        )
      end
    ensure
      server.close
    end
  end
end
