require "json"
require "set"
require "uri"
require "xml"

require "../errors"
require "../extractor"
require "../format"
require "../http_url"
require "../json_value"
require "../media"
require "../mime_type"
require "../timestamp"
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
        uploader: metadata.uploader || metadata.site_name,
        duration_seconds: metadata.duration_seconds,
        thumbnail_url: metadata.thumbnail_url,
        upload_date: metadata.upload_date,
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
        when "script"
          if node["type"]?.try(&.downcase) == "application/ld+json"
            metadata.add_structured_data(node.content)
          end
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
      private struct MediaLink
        getter uri : URI
        getter kind : FormatKind
        getter note : String
        getter extension : String
        getter declared_type : String?

        def initialize(
          @uri : URI,
          @kind : FormatKind,
          @note : String,
          @extension : String,
          @declared_type : String?,
        )
        end
      end

      STRUCTURED_TYPES = %w(
        VideoObject AudioObject MediaObject Movie Clip TVEpisode Episode PodcastEpisode
      )

      getter title : String?
      getter description : String?
      getter site_name : String?
      getter uploader : String?
      getter upload_date : String?
      getter thumbnail_url : URI?
      getter duration_seconds : Float64?
      getter formats = [] of Format

      @width : Int32?
      @height : Int32?
      @thumbnail_candidate : String?
      @video_type : String?
      @audio_type : String?
      @media = [] of MediaLink
      @seen = Set(String).new
      @structured_data = [] of String

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
        when "og:video:type"
          @video_type ||= content
        when "og:audio:type"
          @audio_type ||= content
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

        add_media(source, kind, "source", type)
      end

      def add_structured_data(text : String) : Nil
        @structured_data << text
      end

      def finish(fallback_title : String?) : Nil
        @structured_data.each { |text| apply_structured_data(text) }
        @title ||= fallback_title

        if url = @thumbnail_candidate
          @thumbnail_url = HttpUrl.resolve(@base_url, url)
        end

        @media.each do |entry|
          resolved = resolve_format(entry)
          next unless resolved

          extension, kind = resolved
          audio = kind == FormatKind::Audio
          @formats << Format.new(
            format_id: "media-#{@formats.size + 1}",
            url: entry.uri,
            kind: kind,
            container: extension,
            width: audio ? nil : @width,
            height: audio ? nil : @height,
            duration_seconds: @duration_seconds,
            note: entry.note,
          )
        end
      end

      private def resolve_format(entry : MediaLink) : Tuple(String, FormatKind)?
        extension = entry.extension
        if DirectMedia::VIDEO_EXTENSIONS.includes?(extension)
          return {extension, entry.kind}
        end
        if DirectMedia::AUDIO_EXTENSIONS.includes?(extension)
          return {extension, FormatKind::Audio}
        end

        declared = entry.declared_type
        declared ||= entry.kind == FormatKind::Audio ? @audio_type : @video_type
        mime = MimeType.parse(declared || "")
        return nil unless mime.video? || mime.audio?

        container = mime.container
        return nil unless container

        kind = mime.audio? ? FormatKind::Audio : entry.kind
        {container, kind}
      end

      private def apply_structured_data(text : String) : Nil
        value = JSON.parse(text)
        structured_objects(value).each { |object| apply_structured_object(object) }
      rescue JSON::ParseException
      end

      private def structured_objects(value : JSON::Any) : Array(Hash(String, JSON::Any))
        objects = [] of Hash(String, JSON::Any)
        pending = [value]

        until pending.empty?
          current = pending.pop
          if array = current.as_a?
            pending.concat(array)
          elsif object = current.as_h?
            objects << object
            if graph = object["@graph"]?
              pending << graph
            end
          end
        end

        objects
      end

      private def apply_structured_object(object : Hash(String, JSON::Any)) : Nil
        return unless structured_type?(object["@type"]?) || object["contentUrl"]?

        @title ||= JsonValue.string(object["name"]?)
        @description ||= JsonValue.string(object["description"]?)
        @uploader ||= structured_author(object["author"]?)
        @upload_date ||= date_prefix(JsonValue.string(object["uploadDate"]?))
        @duration_seconds ||= structured_duration(object["duration"]?)
        @width ||= structured_dimension(object["width"]?)
        @height ||= structured_dimension(object["height"]?)
        @thumbnail_candidate ||= structured_thumbnail(
          object["thumbnailUrl"]? || object["image"]?,
        )

        content_url = JsonValue.string(object["contentUrl"]?)
        return unless content_url

        declared_type = JsonValue.string(object["encodingFormat"]?)
        declared_type = nil unless declared_type.try(&.includes?('/'))
        kind = MimeType.parse(declared_type || "").audio? ? FormatKind::Audio : FormatKind::Combined
        add_media(content_url, kind, "json-ld", declared_type)
      end

      private def structured_type?(value : JSON::Any?) : Bool
        if text = value.try(&.as_s?)
          return STRUCTURED_TYPES.includes?(text)
        end

        array = value.try(&.as_a?)
        return false unless array

        array.any? do |item|
          text = item.as_s?
          text ? STRUCTURED_TYPES.includes?(text) : false
        end
      end

      private def structured_author(value : JSON::Any?) : String?
        return nil unless value

        if array = value.as_a?
          array.each do |item|
            name = structured_author(item)
            return name if name
          end
          return nil
        end

        if object = value.as_h?
          JsonValue.string(object["name"]?)
        else
          JsonValue.string(value)
        end
      end

      private def structured_duration(value : JSON::Any?) : Float64?
        return nil unless value

        if number = JsonValue.number(value)
          number if number >= 0
        else
          Timestamp.iso8601_seconds(JsonValue.string(value))
        end
      end

      private def structured_dimension(value : JSON::Any?) : Int32?
        if object = value.try(&.as_h?)
          JsonValue.dimension(object["value"]?)
        else
          JsonValue.dimension(value)
        end
      end

      private def structured_thumbnail(value : JSON::Any?) : String?
        return nil unless value

        if array = value.as_a?
          array.each do |item|
            url = structured_thumbnail(item)
            return url if url
          end
          return nil
        end

        if object = value.as_h?
          JsonValue.string(object["url"]?)
        else
          JsonValue.string(value)
        end
      end

      private def date_prefix(value : String?) : String?
        return nil unless value

        value.size >= 10 ? value[0, 10] : value
      end

      private def positive_int(value : String) : Int32?
        parsed = value.to_i?
        parsed if parsed && parsed > 0
      end

      private def positive_float(value : String) : Float64?
        parsed = value.to_f?
        parsed if parsed && parsed.finite? && parsed > 0
      end

      private def add_media(
        value : String,
        kind : FormatKind,
        note : String,
        declared_type : String? = nil,
      ) : Nil
        uri = HttpUrl.resolve(@base_url, value)
        return unless uri
        return if @seen.includes?(uri.to_s)

        extension = File.extname(uri.path).lchop('.').downcase
        @seen << uri.to_s
        @media << MediaLink.new(
          uri: uri,
          kind: kind,
          note: note,
          extension: extension,
          declared_type: declared_type,
        )
      end
    end
  end
end
