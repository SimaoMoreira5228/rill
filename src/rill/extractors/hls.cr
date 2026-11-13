require "uri"

require "../errors"
require "../extractor"
require "../format"
require "../hls/parser"
require "../hls/playlist"
require "../media"

module Rill::Extractors
  class Hls < Extractor
    def name : String
      "hls"
    end

    def matches?(url : URI) : Bool
      return false unless url.scheme == "http" || url.scheme == "https"

      File.extname(url.path).downcase == ".m3u8"
    end

    def extract(url : URI, client : HTTPClient) : Media
      response = client.get(url)
      playlist = Rill::Hls::Parser.parse(response.body, response.url)

      case playlist
      when Rill::Hls::MultivariantPlaylist
        extract_master(playlist, url)
      when Rill::Hls::MediaPlaylist
        extract_media(playlist, url, response.url)
      else
        raise ManifestError.new("unsupported HLS playlist")
      end
    end

    private def extract_master(
      playlist : Rill::Hls::MultivariantPlaylist,
      url : URI,
    ) : Media
      variants = playlist.variants.reject { |variant| variant.audio_group }
      if variants.empty?
        raise UnsupportedManifestError.new("HLS variants with separate audio are not supported")
      end

      formats = variants.map_with_index do |variant, index|
        format_for_variant(variant, index)
      end

      Media.new(
        title: title_for(url),
        webpage_url: url,
        extractor: name,
        formats: formats,
      )
    end

    private def extract_media(
      playlist : Rill::Hls::MediaPlaylist,
      url : URI,
      playlist_url : URI,
    ) : Media
      format = Format.new(
        format_id: "hls",
        url: playlist_url,
        kind: FormatKind::Combined,
        protocol: FormatProtocol::Hls,
        container: media_container(playlist),
        duration_seconds: playlist.duration_seconds,
        note: "HLS",
      )

      Media.new(
        title: title_for(url),
        webpage_url: url,
        duration_seconds: playlist.duration_seconds,
        extractor: name,
        formats: [format],
      )
    end

    private def format_for_variant(variant : Rill::Hls::Variant, index : Int32) : Format
      Format.new(
        format_id: "hls-#{index + 1}",
        url: variant.url,
        kind: variant.audio_group ? FormatKind::Video : FormatKind::Combined,
        protocol: FormatProtocol::Hls,
        width: variant.width,
        height: variant.height,
        bitrate: variant.bandwidth,
        note: variant.codecs,
      )
    end

    private def media_container(playlist : Rill::Hls::MediaPlaylist) : String?
      return "mp4" if playlist.map_url

      extension = File.extname(playlist.segments.first.url.path).lchop('.').downcase
      extension.empty? ? nil : extension
    end

    private def title_for(url : URI) : String
      basename = File.basename(url.path)
      stem = File.basename(basename, File.extname(basename))
      decoded = URI.decode(stem)
      decoded.empty? ? "stream" : decoded
    end
  end
end
