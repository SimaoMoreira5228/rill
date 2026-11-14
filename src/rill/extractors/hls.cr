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
        extract_master(playlist, url, client)
      when Rill::Hls::MediaPlaylist
        extract_media(playlist, url, response.url)
      else
        raise ManifestError.new("unsupported HLS playlist")
      end
    end

    private struct VariantProbe
      getter container : String?
      getter live : Bool

      def initialize(@container : String?, @live : Bool)
      end
    end

    private def extract_master(
      playlist : Rill::Hls::MultivariantPlaylist,
      url : URI,
      client : HTTPClient,
    ) : Media
      separate = playlist.variants.any? { |variant| separate_audio?(playlist, variant) }
      probe = probe_variant(client, playlist.variants)
      container = probe.container

      if separate && container.nil?
        raise UnsupportedManifestError.new("cannot determine HLS container for separate audio")
      end

      if probe.live && separate
        raise UnsupportedManifestError.new("live HLS with separate audio is not supported")
      end

      formats = playlist.variants.map_with_index do |variant, index|
        kind = separate_audio?(playlist, variant) ? FormatKind::Video : FormatKind::Combined
        format_for_variant(variant, index, kind, container, probe.live)
      end

      warnings = [] of String
      if separate
        audio = audio_renditions(playlist)
        available = playlist.renditions.count { |rendition| rendition.type == "AUDIO" && rendition.url }
        if audio.size < available
          warnings << "only default audio renditions are exposed"
        end

        audio.each_with_index do |rendition, index|
          formats << format_for_audio(rendition, index, container, probe.live)
        end
      end

      Media.new(
        title: title_for(url),
        webpage_url: url,
        extractor: name,
        formats: formats,
        warnings: warnings,
        is_live: probe.live,
      )
    end

    private def separate_audio?(
      playlist : Rill::Hls::MultivariantPlaylist,
      variant : Rill::Hls::Variant,
    ) : Bool
      group = variant.audio_group
      return false unless group

      playlist.renditions.any? do |rendition|
        rendition.type == "AUDIO" && rendition.group_id == group && !rendition.url.nil?
      end
    end

    private def audio_renditions(
      playlist : Rill::Hls::MultivariantPlaylist,
    ) : Array(Rill::Hls::Rendition)
      referenced = playlist.variants.compact_map(&.audio_group)
      groups = {} of String? => Array(Rill::Hls::Rendition)

      playlist.renditions.each do |rendition|
        next unless rendition.type == "AUDIO"
        next unless rendition.url
        next unless referenced.includes?(rendition.group_id)

        list = groups[rendition.group_id]? || begin
          created = [] of Rill::Hls::Rendition
          groups[rendition.group_id] = created
          created
        end
        list << rendition
      end

      groups.values.compact_map do |group|
        group.find(&.default?) || group.find(&.autoselect?) || group.first?
      end
    end

    private def probe_variant(
      client : HTTPClient,
      variants : Array(Rill::Hls::Variant),
    ) : VariantProbe
      variants.each do |variant|
        response = client.get(variant.url)
        playlist = Rill::Hls::Parser.parse(response.body, response.url)
        next unless playlist.is_a?(Rill::Hls::MediaPlaylist)

        return VariantProbe.new(media_container(playlist), !playlist.ended)
      rescue Rill::Error
        next
      end

      VariantProbe.new(nil, false)
    end

    private def extract_media(
      playlist : Rill::Hls::MediaPlaylist,
      url : URI,
      playlist_url : URI,
    ) : Media
      live = !playlist.ended
      format = Format.new(
        format_id: "hls",
        url: playlist_url,
        kind: FormatKind::Combined,
        protocol: FormatProtocol::Hls,
        container: media_container(playlist),
        duration_seconds: playlist.duration_seconds,
        note: "HLS",
        live: live,
      )

      Media.new(
        title: title_for(url),
        webpage_url: url,
        duration_seconds: playlist.duration_seconds,
        extractor: name,
        formats: [format],
        is_live: live,
      )
    end

    private def format_for_variant(
      variant : Rill::Hls::Variant,
      index : Int32,
      kind : FormatKind,
      container : String?,
      live : Bool,
    ) : Format
      Format.new(
        format_id: "hls-#{index + 1}",
        url: variant.url,
        kind: kind,
        protocol: FormatProtocol::Hls,
        container: container,
        width: variant.width,
        height: variant.height,
        bitrate: variant.bandwidth,
        note: variant.codecs,
        live: live,
      )
    end

    private def format_for_audio(
      rendition : Rill::Hls::Rendition,
      index : Int32,
      container : String?,
      live : Bool,
    ) : Format
      Format.new(
        format_id: "audio-#{index + 1}",
        url: rendition.url.not_nil!,
        kind: FormatKind::Audio,
        protocol: FormatProtocol::Hls,
        container: container,
        language: rendition.language,
        note: rendition.name,
        live: live,
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
