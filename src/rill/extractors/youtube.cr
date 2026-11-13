require "http/params"
require "json"
require "set"
require "uri"

require "../errors"
require "../extractor"
require "../format"
require "../media"

module Rill::Extractors
  class YouTube < Extractor
    DEFAULT_API_BASE = "https://www.youtube.com"
    API_KEY          = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
    # NOTE: full browser user agents make YouTube exceed Crystal's 16 KB header limit.
    WATCH_PAGE_USER_AGENT = "Mozilla/5.0"
    VISIONOS_USER_AGENT   = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) " \
                            "AppleWebKit/605.1.15 (KHTML, like Gecko) " \
                            "Version/26.0 Safari/605.1.15"
    VIDEO_ID = /\A[A-Za-z0-9_-]{11}\z/

    HOSTS = {
      "youtube.com",
      "www.youtube.com",
      "m.youtube.com",
      "music.youtube.com",
      "youtu.be",
      "www.youtu.be",
      "youtube-nocookie.com",
      "www.youtube-nocookie.com",
    }

    struct PlayerClient
      getter name : String
      getter identifier : String
      getter version : String
      getter user_agent : String
      getter context : Hash(String, String)

      def initialize(
        @name : String,
        @identifier : String,
        @version : String,
        @user_agent : String,
        @context : Hash(String, String),
      )
      end
    end

    struct Bootstrap
      getter visitor_data : String?
      getter api_key : String?

      def initialize(@visitor_data : String? = nil, @api_key : String? = nil)
      end
    end

    VISIONOS = PlayerClient.new(
      "visionos",
      "101",
      "1.02",
      VISIONOS_USER_AGENT,
      {
        "clientName"  => "VISIONOS",
        "deviceMake"  => "Apple",
        "deviceModel" => "RealityDevice17,1",
        "osName"      => "visionOS",
        "osVersion"   => "26.5.23O471",
      },
    )

    TV_SAMSUNG = PlayerClient.new(
      "tv_samsung",
      "7",
      "5.20260707",
      "Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0) AppleWebKit/538.1 " \
      "(KHTML, like Gecko) Version/2.4.0 TV Safari/538.1",
      {
        "clientName"  => "TVHTML5",
        "deviceMake"  => "Samsung",
        "deviceModel" => "UKS9800",
        "osName"      => "Tizen",
        "osVersion"   => "2.4.0",
      },
    )

    CLIENTS = {VISIONOS, TV_SAMSUNG}

    def initialize(@api_base : String = DEFAULT_API_BASE)
    end

    def name : String
      "youtube"
    end

    def matches?(url : URI) : Bool
      return false unless url.scheme == "http" || url.scheme == "https"

      !video_id_for(url).nil?
    end

    def extract(url : URI, client : HTTPClient) : Media
      video_id = video_id_for(url)
      unless video_id
        raise UnsupportedUrlError.new(url.to_s)
      end

      bootstrap = watch_page(client, video_id)
      errors = [] of String

      CLIENTS.each do |player_client|
        begin
          payload = player_payload(client, player_client, video_id, bootstrap, url)

          if reason = playability_error(payload)
            errors << "#{player_client.name}: #{reason}"
            next
          end

          details = payload["videoDetails"]?.try(&.as_h?)
          unless details
            errors << "#{player_client.name}: video details are missing"
            next
          end

          if details["isLiveContent"]?.try(&.as_bool?)
            raise MediaUnavailableError.new(url.to_s, "live videos are not supported")
          end

          formats = formats_from(payload["streamingData"]?)
          if formats.empty?
            errors << "#{player_client.name}: no direct formats; JavaScript challenge support is required"
            next
          end

          return build_media(details, payload, formats, video_id, url)
        rescue ex : MediaUnavailableError
          errors << "#{player_client.name}: #{ex.message}"
        rescue ex : HTTPError
          errors << "#{player_client.name}: HTTP #{ex.status.code}"
        end
      end

      raise MediaUnavailableError.new(url.to_s, errors.uniq.join("; "))
    end

    private def build_media(
      details : Hash(String, JSON::Any),
      payload : Hash(String, JSON::Any),
      formats : Array(Format),
      video_id : String,
      url : URI,
    ) : Media
      Media.new(
        id: scalar_string(details["videoId"]?) || video_id,
        title: scalar_string(details["title"]?) || video_id,
        description: scalar_string(details["shortDescription"]?),
        webpage_url: url,
        uploader: scalar_string(details["author"]?),
        duration_seconds: parse_seconds(details["lengthSeconds"]?),
        thumbnail_url: thumbnail_url(details),
        upload_date: upload_date(payload),
        extractor: name,
        formats: formats,
      )
    end

    private def watch_page(client : HTTPClient, video_id : String) : Bootstrap
      headers = HTTP::Headers.new
      headers["User-Agent"] = WATCH_PAGE_USER_AGENT
      headers["Accept-Language"] = "en-US,en;q=0.9"

      endpoint = "#{@api_base}/watch?v=#{video_id}&bpctr=9999999999&has_verified=1"
      body = client.get(endpoint, headers).body

      visitor = body.match(/"VISITOR_DATA":"([^"]+)"/) ||
                body.match(/"visitorData":"([^"]+)"/)
      api_key = body.match(/"INNERTUBE_API_KEY":"([^"]+)"/)

      Bootstrap.new(visitor.try(&.[1]), api_key.try(&.[1]))
    rescue Rill::Error
      Bootstrap.new
    end

    private def player_payload(
      client : HTTPClient,
      player_client : PlayerClient,
      video_id : String,
      bootstrap : Bootstrap,
      url : URI,
    ) : Hash(String, JSON::Any)
      body = JSON.build do |json|
        json.object do
          json.field "context" do
            json.object do
              json.field "client" do
                json.object do
                  player_client.context.each do |key, value|
                    json.field key, value
                  end
                  json.field "clientVersion", player_client.version
                  json.field "hl", "en"
                  json.field "timeZone", "UTC"
                  json.field "utcOffsetMinutes", 0
                end
              end
            end
          end
          json.field "videoId", video_id
          json.field "contentCheckOk", true
          json.field "racyCheckOk", true
        end
      end

      headers = HTTP::Headers.new
      headers["User-Agent"] = player_client.user_agent
      headers["X-YouTube-Client-Name"] = player_client.identifier
      headers["X-YouTube-Client-Version"] = player_client.version
      headers["Origin"] = @api_base
      headers["Referer"] = "#{@api_base}/"
      if visitor = bootstrap.visitor_data
        headers["X-Goog-Visitor-Id"] = visitor
      end

      api_key = bootstrap.api_key || API_KEY
      endpoint = "#{@api_base}/youtubei/v1/player?key=#{api_key}&prettyPrint=false"
      response = client.post(endpoint, body, headers)

      payload = JSON.parse(response.body).as_h?
      unless payload
        raise MediaUnavailableError.new(url.to_s, "player response is not a JSON object")
      end

      payload
    rescue JSON::ParseException
      raise MediaUnavailableError.new(url.to_s, "player response is not valid JSON")
    rescue ex : HTTPError
      case ex.status.code
      when 400, 403, 429
        raise MediaUnavailableError.new(url.to_s, "player API rejected the request (#{ex.status.code})")
      else
        raise ex
      end
    end

    private def playability_error(payload : Hash(String, JSON::Any)) : String?
      status = payload["playabilityStatus"]?.try(&.as_h?)
      state = status.try(&.["status"]?).try(&.as_s?)
      return nil if state == "OK"

      reason = status.try(&.["reason"]?).try(&.as_s?)
      reason || "video is not playable (#{state || "unknown"})"
    end

    private def formats_from(streaming_value : JSON::Any?) : Array(Format)
      streaming = streaming_value.try(&.as_h?)
      return [] of Format unless streaming

      formats = [] of Format
      seen = Set(String).new

      {"formats", "adaptiveFormats"}.each do |key|
        items = streaming[key]?.try(&.as_a?) || [] of JSON::Any

        items.each do |item|
          format = format_from(item)
          next unless format
          next if seen.includes?(format.format_id)

          seen << format.format_id
          formats << format
        end
      end

      formats
    end

    private def format_from(item : JSON::Any) : Format?
      value = item.as_h?
      return nil unless value

      url = parse_uri(scalar_string(value["url"]?))
      return nil unless url
      return nil if value["signatureCipher"]?

      itag = integer(value["itag"]?)
      return nil unless itag

      mime_type = scalar_string(value["mimeType"]?) || ""
      type, container, codecs = parse_mime_type(mime_type)
      return nil if type.empty?

      width = dimension(value["width"]?)
      height = dimension(value["height"]?)
      has_video = type.starts_with?("video/") && (!width.nil? || !height.nil?)
      has_audio = type.starts_with?("audio/") ||
                  (integer(value["audioChannels"]?) || 0) > 0
      return nil unless has_video || has_audio

      codec_list = codecs.try(&.split(',').map(&.strip).reject(&.empty?)) || [] of String

      video_codec = if has_video
                      codec_list.first?
                    end
      audio_codec = if has_audio
                      has_video ? codec_list[1]? : codec_list.first?
                    end

      Format.new(
        format_id: itag.to_s,
        url: url,
        kind: format_kind(has_video, has_audio),
        container: container,
        bitrate: integer(value["bitrate"]?),
        video_codec: video_codec,
        audio_codec: audio_codec,
        width: width,
        height: height,
        fps: positive_number(value["fps"]?),
        filesize: integer(value["contentLength"]?),
        language: audio_language(value),
        note: scalar_string(value["qualityLabel"]?) || scalar_string(value["audioQuality"]?),
      )
    end

    private def format_kind(has_video : Bool, has_audio : Bool) : FormatKind
      if has_video && has_audio
        FormatKind::Combined
      elsif has_video
        FormatKind::Video
      else
        FormatKind::Audio
      end
    end

    private def audio_language(value : Hash(String, JSON::Any)) : String?
      track = value["audioTrack"]?.try(&.as_h?)
      return nil unless track

      scalar_string(track["displayName"]?) || scalar_string(track["id"]?)
    end

    private def thumbnail_url(details : Hash(String, JSON::Any)) : URI?
      thumbnail = details["thumbnail"]?.try(&.as_h?)
      return nil unless thumbnail

      images = thumbnail["thumbnails"]?.try(&.as_a?)
      return nil unless images

      images.reverse_each do |image|
        image_hash = image.as_h?
        next unless image_hash

        uri = parse_uri(scalar_string(image_hash["url"]?))
        return uri if uri
      end

      nil
    end

    private def upload_date(payload : Hash(String, JSON::Any)) : String?
      microformat = payload["microformat"]?.try(&.as_h?)
      return nil unless microformat

      renderer = microformat["playerMicroformatRenderer"]?.try(&.as_h?)
      return nil unless renderer

      value = scalar_string(renderer["publishDate"]?) || scalar_string(renderer["uploadDate"]?)
      return nil unless value
      return nil if value.size < 10

      value[0, 10]
    end

    private def parse_mime_type(value : String) : Tuple(String, String?, String?)
      parts = value.split(';').map(&.strip)
      media_type = parts.first?.try(&.downcase) || ""
      codecs = parts.skip(1).compact_map do |part|
        name, separator, codec = part.partition('=')
        next unless separator == "=" && name.strip.downcase == "codecs"

        codec = codec.strip
        if codec.starts_with?('"') && codec.ends_with?('"')
          codec = codec[1..-2]
        end
        codec
      end.first?

      subtype = media_type.split('/').last?
      container = subtype
      if container == "mpeg"
        container = "mp3"
      end

      {media_type, container, codecs}
    end

    private def video_id_for(url : URI) : String?
      host = url.host.try(&.downcase)
      return nil unless host && HOSTS.includes?(host)

      path = url.path

      if host.ends_with?("youtu.be")
        return valid_id?(path.lchop('/').split('/').first?)
      end

      if path == "/watch"
        query = HTTP::Params.parse(url.query || "")
        return valid_id?(query["v"]?)
      end

      match = %r{\A/(?:shorts|embed|live|v)/([^/]+)/?\z}.match(path)
      return nil unless match

      valid_id?(match[1])
    end

    private def valid_id?(value : String?) : String?
      return nil unless value
      return nil unless VIDEO_ID.matches?(value)

      value
    end

    private def dimension(value : JSON::Any?) : Int32?
      number = integer(value)
      return nil unless number && 0 < number <= 100_000

      number.to_i32
    end

    private def parse_seconds(value : JSON::Any?) : Float64?
      seconds = scalar_string(value).try(&.to_f?)
      return nil unless seconds && seconds.finite? && seconds >= 0

      seconds
    end

    private def positive_number(value : JSON::Any?) : Float64?
      number = value.try(&.as_f?) || value.try(&.as_i64?).try(&.to_f)
      return nil unless number && number.finite? && number > 0

      number
    end

    private def integer(value : JSON::Any?) : Int64?
      return nil unless value

      if string = value.as_s?
        string.to_i64?
      else
        value.as_i64?
      end
    end

    private def scalar_string(value : JSON::Any?) : String?
      return nil unless value

      if string = value.as_s?
        string
      elsif integer = value.as_i64?
        integer.to_s
      elsif float = value.as_f?
        float.to_s
      else
        nil
      end
    end

    private def parse_uri(value : String?) : URI?
      return nil unless value

      uri = URI.parse(value)
      return nil unless uri.scheme == "http" || uri.scheme == "https"
      return nil if uri.host.nil?

      uri
    rescue URI::Error
      nil
    end
  end
end
