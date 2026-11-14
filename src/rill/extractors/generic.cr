require "set"
require "uri"
require "xml"

require "../errors"
require "../extractor"
require "../format"
require "../media"
require "../mime_type"
require "./direct_media"

module Rill::Extractors
  class Generic < Extractor
    def name : String
      "generic"
    end

    def matches?(url : URI) : Bool
      url.scheme == "http" || url.scheme == "https"
    end

    def extract(url : URI, client : HTTPClient) : Media
      response = client.get(url)
      content_type = response.headers["Content-Type"]?.try(&.split(';').first.strip) || ""

      mime = MimeType.parse(content_type)
      if mime.video? || mime.audio?
        return direct_media(url, response.url, mime, response.body.bytesize)
      end

      metadata = page_metadata(response.body, response.url)
      formats = metadata.formats
      if formats.empty?
        raise MediaUnavailableError.new(url.to_s, "no direct media links were found")
      end

      Media.new(
        title: metadata.title || fallback_title(url),
        description: metadata.description,
        webpage_url: url,
        uploader: metadata.site_name,
        duration_seconds: metadata.duration_seconds,
        thumbnail_url: metadata.thumbnail_url,
        extractor: name,
        formats: formats,
      )
    end

    private def direct_media(
      original_url : URI,
      response_url : URI,
      mime : MimeType,
      size : Int64,
    ) : Media
      format = Format.new(
        format_id: "direct",
        url: response_url,
        kind: mime.audio? ? FormatKind::Audio : FormatKind::Combined,
        container: mime.container,
        filesize: size,
        note: "direct response",
      )

      Media.new(
        title: fallback_title(original_url),
        webpage_url: original_url,
        extractor: name,
        formats: [format],
      )
    end

    private def page_metadata(body : String, base_url : URI) : PageMetadata
      document = XML.parse_html(body)
      metadata = PageMetadata.new(base_url)
      first_title = nil.as(String?)

      each_element(document) do |node|
        case node.name.downcase
        when "title"
          first_title ||= node.content.strip
        when "meta"
          metadata.add_meta(node)
        when "video"
          metadata.add_video(node)
        when "audio"
          metadata.add_audio(node)
        when "source"
          metadata.add_source(node)
        end
      end

      metadata.finish(first_title)
      metadata
    rescue XML::Error
      raise MediaUnavailableError.new(base_url.to_s, "page is not valid HTML")
    end

    private def each_element(root : XML::Node, & : XML::Node ->) : Nil
      pending = root.children.select(&.element?).to_a
      index = 0

      while index < pending.size
        node = pending[index]
        index += 1

        yield node

        node.children.each do |child|
          pending << child if child.element?
        end
      end
    end

    private def fallback_title(url : URI) : String
      basename = File.basename(url.path)
      stem = File.basename(basename, File.extname(basename))
      decoded = URI.decode(stem)
      decoded.empty? ? url.host.to_s : decoded
    end

    private class PageMetadata
      getter title : String?
      getter description : String?
      getter site_name : String?
      getter thumbnail_url : URI?
      getter duration_seconds : Float64?
      getter formats = [] of Format

      @width : Int32?
      @height : Int32?
      @thumbnail_candidate : String?
      @media = [] of NamedTuple(uri: URI, kind: FormatKind, note: String, extension: String)
      @seen = Set(String).new

      def initialize(@base_url : URI)
      end

      def add_meta(node : XML::Node) : Nil
        key = node["property"]? || node["name"]?
        content = node["content"]?
        return unless key && content

        case key.downcase
        when "og:title", "twitter:title"
          @title ||= content
        when "og:description", "description", "twitter:description"
          @description ||= content
        when "og:site_name"
          @site_name ||= content
        when "og:image", "twitter:image"
          @thumbnail_candidate ||= content
        when "og:video:width"
          @width ||= positive_int(content)
        when "og:video:height"
          @height ||= positive_int(content)
        when "og:video:duration"
          @duration_seconds ||= positive_float(content)
        when "og:video", "og:video:url", "og:video:secure_url"
          add_media(content, FormatKind::Combined, "og:video")
        when "og:audio", "og:audio:url", "og:audio:secure_url"
          add_media(content, FormatKind::Audio, "og:audio")
        when "twitter:player:stream"
          add_media(content, FormatKind::Combined, "twitter:stream")
        end
      end

      def add_video(node : XML::Node) : Nil
        if poster = node["poster"]?
          @thumbnail_candidate ||= poster
        end
        if source = node["src"]?
          add_media(source, FormatKind::Combined, "video")
        end
      end

      def add_audio(node : XML::Node) : Nil
        if source = node["src"]?
          add_media(source, FormatKind::Audio, "audio")
        end
      end

      def add_source(node : XML::Node) : Nil
        source = node["src"]?
        return unless source

        type = node["type"]?
        kind = if type.try(&.downcase.starts_with?("audio/"))
                 FormatKind::Audio
               else
                 FormatKind::Combined
               end

        add_media(source, kind, "source")
      end

      def finish(fallback_title : String?) : Nil
        @title ||= fallback_title

        if url = @thumbnail_candidate
          @thumbnail_url = resolve(url)
        end

        @media.each do |entry|
          audio = DirectMedia::AUDIO_EXTENSIONS.includes?(entry[:extension])
          @formats << Format.new(
            format_id: "media-#{@formats.size + 1}",
            url: entry[:uri],
            kind: audio ? FormatKind::Audio : entry[:kind],
            container: entry[:extension],
            width: audio ? nil : @width,
            height: audio ? nil : @height,
            duration_seconds: @duration_seconds,
            note: entry[:note],
          )
        end
      end

      private def positive_int(value : String) : Int32?
        parsed = value.to_i?
        parsed if parsed && parsed > 0
      end

      private def positive_float(value : String) : Float64?
        parsed = value.to_f?
        parsed if parsed && parsed.finite? && parsed > 0
      end

      private def add_media(value : String, kind : FormatKind, note : String) : Nil
        uri = resolve(value)
        return unless uri
        return if @seen.includes?(uri.to_s)

        extension = File.extname(uri.path).lchop('.').downcase
        return unless DirectMedia::VIDEO_EXTENSIONS.includes?(extension) ||
                      DirectMedia::AUDIO_EXTENSIONS.includes?(extension)

        @seen << uri.to_s
        @media << {uri: uri, kind: kind, note: note, extension: extension}
      end

      private def resolve(value : String) : URI?
        uri = @base_url.resolve(value)
        return nil unless uri.scheme == "http" || uri.scheme == "https"
        return nil if uri.host.nil?

        uri
      rescue URI::Error
        nil
      end
    end
  end
end
