require "../../spec_helper"

private def bandcamp_track_url : String
  "https://benprunty.bandcamp.com/track/lanius-battle"
end

private def bandcamp_album_url : String
  "https://blazo.bandcamp.com/album/jazz-format-mixtape-vol-1"
end

describe Rill::Extractors::Bandcamp do
  it "matches track and album pages" do
    extractor = Rill::Extractors::Bandcamp.new

    extractor.matches?(URI.parse(bandcamp_track_url)).should be_true
    extractor.matches?(URI.parse(bandcamp_album_url)).should be_true
    extractor.matches?(URI.parse("http://artist.bandcamp.com/track/slug")).should be_true
    extractor.matches?(URI.parse("https://artist.bandcamp.com/album/slug/")).should be_true
    extractor.matches?(URI.parse("https://artist.bandcamp.com/track/slug?from=embed")).should be_true
  end

  it "rejects other hosts and paths" do
    extractor = Rill::Extractors::Bandcamp.new

    extractor.matches?(URI.parse("https://bandcamp.com/track/slug")).should be_false
    extractor.matches?(URI.parse("https://www.bandcamp.com/track/slug")).should be_false
    extractor.matches?(URI.parse("https://example.com/track/slug")).should be_false
    extractor.matches?(URI.parse("https://artist.example.com/track/slug")).should be_false
    extractor.matches?(URI.parse("https://a.b.bandcamp.com/track/slug")).should be_false
    extractor.matches?(URI.parse("https://artist.bandcamp.com/track")).should be_false
    extractor.matches?(URI.parse("https://artist.bandcamp.com/track/slug/extra")).should be_false
    extractor.matches?(URI.parse("https://artist.bandcamp.com/music")).should be_false
    extractor.matches?(URI.parse("ftp://artist.bandcamp.com/track/slug")).should be_false
  end

  it "extracts a track" do
    server = TestHTTPServer.new
    server.on("/track/lanius-battle") do |_, response|
      response.content_type = "text/html"
      response.print(fixture("bandcamp", "track.html"))
    end
    server.start

    begin
      media = Rill::Extractors::Bandcamp.new.extract(
        URI.parse("#{server.url}/track/lanius-battle"),
        Rill::HTTPClient.new,
      ).as(Rill::Media)
      media.validate!

      media.id.should eq("2650410135")
      media.title.should eq("Lanius (Battle)")
      media.uploader.should eq("Ben Prunty")
      media.duration_seconds.not_nil!.should be_close(260.877, 0.001)
      media.upload_date.should eq("2014-04-03")
      media.thumbnail_url.not_nil!.to_s.should eq("https://f4.bcbits.com/img/a1270682128_5.jpg")
      media.extractor.should eq("bandcamp")
      media.formats.size.should eq(1)

      format = media.formats.first
      format.format_id.should eq("mp3-128")
      format.kind.should eq(Rill::FormatKind::Audio)
      format.container.should eq("mp3")
      format.bitrate.should eq(128_000_i64)
      format.duration_seconds.not_nil!.should be_close(260.877, 0.001)
      format.url.to_s.should eq(
        "https://t4.bcbits.com/stream/9b90dc836321f5d247bfcc6adf7afd70/" \
        "mp3-128/2650410135?p=0&ts=1794708734&token=test",
      )
    ensure
      server.close
    end
  end

  it "normalizes ISO release dates" do
    body = fixture("bandcamp", "track.html").sub(
      %(&quot;release_date&quot;:null),
      %(&quot;release_date&quot;:&quot;2014-04-03T00:00:00+00:00&quot;),
    )

    server = TestHTTPServer.new
    server.on("/track/lanius-battle") { |_, response| response.print(body) }
    server.start

    begin
      media = Rill::Extractors::Bandcamp.new.extract(
        URI.parse("#{server.url}/track/lanius-battle"),
        Rill::HTTPClient.new,
      ).as(Rill::Media)

      media.upload_date.should eq("2014-04-03")
    ensure
      server.close
    end
  end

  it "extracts an album as a playlist" do
    server = TestHTTPServer.new
    server.on("/album/jazz-format-mixtape-vol-1") do |_, response|
      response.content_type = "text/html"
      response.print(fixture("bandcamp", "album.html"))
    end
    server.start

    begin
      playlist = Rill::Extractors::Bandcamp.new.extract(
        URI.parse("#{server.url}/album/jazz-format-mixtape-vol-1"),
        Rill::HTTPClient.new,
      ).as(Rill::Playlist)
      playlist.validate!

      playlist.id.should eq("4200675537")
      playlist.title.should eq("Jazz Format Mixtape vol.1")
      playlist.extractor.should eq("bandcamp")
      playlist.entries.size.should eq(3)

      playlist.entries[0].id.should eq("1353101989")
      playlist.entries[0].title.should eq("Intro")
      playlist.entries[0].url.to_s.should eq("#{server.url}/track/intro")

      playlist.entries[1].title.should eq("Kero One - Keep It Alive (Blazo remix)")
      playlist.entries[1].url.to_s.should eq(
        "#{server.url}/track/kero-one-keep-it-alive-blazo-remix",
      )

      playlist.entries[2].url.to_s.should eq("#{server.url}/track/shinsight-trio-heart")
    ensure
      server.close
    end
  end

  it "reports pages without data-tralbum as unavailable" do
    server = TestHTTPServer.new
    server.on("/track/private") do |_, response|
      response.content_type = "text/html"
      response.print("<html><body>private</body></html>")
    end
    server.start

    begin
      extractor = Rill::Extractors::Bandcamp.new
      expect_raises(Rill::MediaUnavailableError, /data-tralbum/) do
        extractor.extract(URI.parse("#{server.url}/track/private"), Rill::HTTPClient.new)
      end
    ensure
      server.close
    end
  end

  it "reports tracks without a stream as unavailable" do
    tralbum = %({"current":{"title":"Test"},"trackinfo":[{"id":1,"title":"Test","duration":10}]})
    body = %(<html><body><div data-tralbum='#{tralbum}'></div></body></html>)

    server = TestHTTPServer.new
    server.on("/track/lanius-battle") { |_, response| response.print(body) }
    server.start

    begin
      extractor = Rill::Extractors::Bandcamp.new
      expect_raises(Rill::MediaUnavailableError, /stream/) do
        extractor.extract(URI.parse("#{server.url}/track/lanius-battle"), Rill::HTTPClient.new)
      end
    ensure
      server.close
    end
  end
end
