require "uri"

require "../errors"
require "../extractor"
require "../http_url"
require "../media"
require "../playlist"

module Rill::Extractors
  class M3u < Extractor
    EXTINF = "#EXTINF:"

    def name : String
      "m3u"
    end

    def matches?(url : URI) : Bool
      return false unless url.scheme == "http" || url.scheme == "https"

      File.extname(url.path).downcase == ".m3u"
    end

    def extract(url : URI, client : HTTPClient) : Playlist
      response = client.get(url)

      if response.body.includes?("#EXT-X-")
        raise UnsupportedManifestError.new("HLS playlists must use a .m3u8 URL")
      end

      entries = parse_entries(response.body, response.url)
      if entries.empty?
        raise MediaUnavailableError.new(url.to_s, "playlist has no entries")
      end

      Playlist.new(
        title: title_for(url),
        webpage_url: url,
        extractor: name,
        entries: entries,
      )
    end

    private def parse_entries(body : String, base_url : URI) : Array(PlaylistEntry)
      entries = [] of PlaylistEntry
      pending_title : String? = nil

      body.lchop('\uFEFF').each_line do |raw|
        line = raw.strip
        next if line.empty?

        if line.starts_with?(EXTINF)
          pending_title = parse_title(line[EXTINF.size..])
        elsif line.starts_with?('#')
          next
        else
          if entry_url = HttpUrl.resolve(base_url, line)
            entries << PlaylistEntry.new(url: entry_url, title: pending_title)
          end
          pending_title = nil
        end
      end

      entries
    end

    private def parse_title(value : String) : String?
      _, separator, title = value.partition(',')
      return nil if separator.empty?

      title = title.strip
      title.empty? ? nil : title
    end

    private def title_for(url : URI) : String
      basename = File.basename(url.path)
      stem = File.basename(basename, File.extname(basename))
      decoded = URI.decode(stem)
      decoded.empty? ? "playlist" : decoded
    end
  end
end
