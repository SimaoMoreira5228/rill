require "http/params"
require "json"
require "set"
require "uri"

require "../errors"
require "../extractor"
require "../format"
require "../http_url"
require "../json_value"
require "../media"
require "../mime_type"
require "../timestamp"

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

    SEARCH_CLIENT = PlayerClient.new(
      "web",
      "1",
      "2.20260707.01.00",
      "Mozilla/5.0",
      {"clientName" => "WEB"},
    )

    struct SearchResult
      getter video_id : String
      getter title : String
      getter duration_seconds : Float64?

      def initialize(
        @video_id : String,
        @title : String,
        @duration_seconds : Float64? = nil,
      )
      end
    end

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

    def search(query : String, client : HTTPClient, limit : Int32 = 5) : Array(SearchResult)
      body = JSON.build do |json|
        json.object do
          json.field "context" do
            json.object do
              json.field "client" do
                json.object do
                  json.field "clientName", SEARCH_CLIENT.context["clientName"]
                  json.field "clientVersion", SEARCH_CLIENT.version
                  json.field "hl", "en"
                  json.field "gl", "US"
                end
              end
            end
          end
          json.field "query", query
          json.field "params", "EgIQAQ%3D%3D"
        end
      end

      headers = HTTP::Headers.new
      headers["User-Agent"] = SEARCH_CLIENT.user_agent
      headers["X-YouTube-Client-Name"] = SEARCH_CLIENT.identifier
      headers["X-YouTube-Client-Version"] = SEARCH_CLIENT.version
      headers["Origin"] = @api_base
      headers["Referer"] = "#{@api_base}/"

      endpoint = "#{@api_base}/youtubei/v1/search?key=#{API_KEY}&prettyPrint=false"
      response = client.post(endpoint, body, headers)
      payload = JSON.parse(response.body)

      results = [] of SearchResult
      collect_search_results(payload, results, limit)
      results
    rescue JSON::ParseException
      raise MediaUnavailableError.new("#{@api_base}/", "search response is not valid JSON")
    rescue ex : HTTPError
      raise MediaUnavailableError.new("#{@api_base}/", "search request failed (#{ex.status.code})")
    end

    private def collect_search_results(
      value : JSON::Any,
      results : Array(SearchResult),
      limit : Int32,
    ) : Nil
      return if results.size >= limit

      if hash = value.as_h?
        if renderer = hash["videoRenderer"]?.try(&.as_h?)
          result = search_result(renderer)
          results << result if result
        end

        hash.each_value do |child|
          collect_search_results(child, results, limit)
          return if results.size >= limit
        end
      elsif array = value.as_a?
        array.each do |child|
          collect_search_results(child, results, limit)
          return if results.size >= limit
        end
      end
    end

    private def search_result(renderer : Hash(String, JSON::Any)) : SearchResult?
      video_id = JsonValue.string(renderer["videoId"]?)
      return nil unless video_id

      title = text_runs(renderer["title"]?) || video_id
      duration = Timestamp.clock_seconds(text_runs(renderer["lengthText"]?))

      SearchResult.new(video_id, title, duration)
    end

    private def text_runs(value : JSON::Any?) : String?
      hash = value.try(&.as_h?)
      return nil unless hash

      if runs = hash["runs"]?.try(&.as_a?)
        text = runs.compact_map do |run|
          run_hash = run.as_h?
          JsonValue.string(run_hash.try(&.["text"]?))
        end.join

        return text unless text.empty?
      end

      JsonValue.string(hash["simpleText"]?)
    end

    private def build_media(
      details : Hash(String, JSON::Any),
      payload : Hash(String, JSON::Any),
      formats : Array(Format),
      video_id : String,
      url : URI,
    ) : Media
      Media.new(
        id: JsonValue.string(details["videoId"]?) || video_id,
        title: JsonValue.string(details["title"]?) || video_id,
        description: JsonValue.string(details["shortDescription"]?),
        webpage_url: url,
        uploader: JsonValue.string(details["author"]?),
        duration_seconds: JsonValue.seconds(details["lengthSeconds"]?),
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

      url = HttpUrl.absolute(JsonValue.string(value["url"]?))
      return nil unless url
      return nil if value["signatureCipher"]?

      itag = JsonValue.integer(value["itag"]?)
      return nil unless itag

      mime_type = JsonValue.string(value["mimeType"]?) || ""
      mime = MimeType.parse(mime_type)
      return nil if mime.empty?

      width = JsonValue.dimension(value["width"]?)
      height = JsonValue.dimension(value["height"]?)
      has_video = mime.video? && (!width.nil? || !height.nil?)
      has_audio = mime.audio? ||
                  (JsonValue.integer(value["audioChannels"]?) || 0) > 0
      return nil unless has_video || has_audio

      codec_list = mime.codec_list

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
        container: mime.container,
        bitrate: JsonValue.integer(value["bitrate"]?),
        video_codec: video_codec,
        audio_codec: audio_codec,
        width: width,
        height: height,
        fps: JsonValue.positive_number(value["fps"]?),
        filesize: JsonValue.integer(value["contentLength"]?),
        range_chunk_size: 1024_i64 * 1024,
        language: audio_language(value),
        note: JsonValue.string(value["qualityLabel"]?) || JsonValue.string(value["audioQuality"]?),
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

      JsonValue.string(track["displayName"]?) || JsonValue.string(track["id"]?)
    end

    private def thumbnail_url(details : Hash(String, JSON::Any)) : URI?
      thumbnail = details["thumbnail"]?.try(&.as_h?)
      return nil unless thumbnail

      images = thumbnail["thumbnails"]?.try(&.as_a?)
      return nil unless images

      images.reverse_each do |image|
        image_hash = image.as_h?
        next unless image_hash

        uri = HttpUrl.absolute(JsonValue.string(image_hash["url"]?))
        return uri if uri
      end

      nil
    end

    private def upload_date(payload : Hash(String, JSON::Any)) : String?
      microformat = payload["microformat"]?.try(&.as_h?)
      return nil unless microformat

      renderer = microformat["playerMicroformatRenderer"]?.try(&.as_h?)
      return nil unless renderer

      value = JsonValue.string(renderer["publishDate"]?) || JsonValue.string(renderer["uploadDate"]?)
      return nil unless value
      return nil if value.size < 10

      value[0, 10]
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
  end
end
