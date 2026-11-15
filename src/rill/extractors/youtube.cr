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
require "./hls"

module Rill::Extractors
  class YouTube < Extractor
    DEFAULT_API_BASE = "https://www.youtube.com"
    API_KEY          = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
    # NOTE: full browser user agents make YouTube exceed Crystal's 16 KB header limit.
    WATCH_PAGE_USER_AGENT = "Mozilla/5.0"
    VISIONOS_USER_AGENT   = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) " \
                            "AppleWebKit/605.1.15 (KHTML, like Gecko) " \
                            "Version/26.0 Safari/605.1.15"
    VIDEO_ID    = /\A[A-Za-z0-9_-]{11}\z/
    PLAYLIST_ID = /\A[A-Za-z0-9_-]{2,}\z/
    # NOTE: without the consent cookie YouTube redirects page requests to consent.youtube.com.
    PAGE_COOKIE = "SOCS=CAI"

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
      getter js_url : String?

      def initialize(
        @visitor_data : String? = nil,
        @api_key : String? = nil,
        @js_url : String? = nil,
      )
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

    ANDROID_VR = PlayerClient.new(
      "android_vr",
      "28",
      "1.65.10",
      "com.google.android.apps.youtube.vr.oculus/1.65.10 " \
      "(Linux; U; Android 12L; en_US; Quest 3 Build/SQ3A.220605.009.A1) gzip",
      {
        "clientName"        => "ANDROID_VR",
        "deviceMake"        => "Oculus",
        "deviceModel"       => "Quest 3",
        "platform"          => "MOBILE",
        "osName"            => "Android",
        "osVersion"         => "12L",
        "androidSdkVersion" => "32",
        "gl"                => "US",
      },
    )

    ANDROID = PlayerClient.new(
      "android",
      "3",
      "21.03.36",
      "com.google.android.youtube/21.03.36 (Linux; U; Android 15; US) gzip",
      {
        "clientName"        => "ANDROID",
        "clientScreen"      => "WATCH",
        "platform"          => "MOBILE",
        "osName"            => "Android",
        "osVersion"         => "15",
        "androidSdkVersion" => "35",
        "gl"                => "US",
      },
    )

    WEB = PlayerClient.new(
      "web",
      "1",
      "2.20260707.01.00",
      "Mozilla/5.0",
      {"clientName" => "WEB"},
    )

    CLIENTS = {VISIONOS, ANDROID_VR, ANDROID, TV_SAMSUNG, WEB}

    SEARCH_CLIENT = WEB

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

    @solver : Solver? = nil
    @solver_loaded = false

    def initialize(@api_base : String = DEFAULT_API_BASE)
    end

    def name : String
      "youtube"
    end

    def matches?(url : URI) : Bool
      return false unless url.scheme == "http" || url.scheme == "https"

      !video_id_for(url).nil? || !playlist_id_for(url).nil? || !channel_path_for(url).nil?
    end

    def extract(url : URI, client : HTTPClient) : Media | Playlist
      if channel = channel_path_for(url)
        return extract_channel(url, channel.path, channel.tab, client)
      end

      if playlist_id = playlist_id_for(url)
        return extract_playlist(url, playlist_id, client)
      end

      video_id = video_id_for(url)
      unless video_id
        raise UnsupportedUrlError.new(url.to_s)
      end

      bootstrap = ensure_visitor_data(client, watch_page(client, video_id))
      errors = [] of String

      CLIENTS.each do |player_client|
        begin
          player_token = nil
          gvs_token = nil
          if player_client.name == WEB.name
            player_token, gvs_token = web_po_tokens(client, video_id, bootstrap)
          end

          payload = player_payload(client, player_client, video_id, bootstrap, url, player_token)

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
            if hls_url = live_hls_url(payload)
              hls_url = with_pot(hls_url, gvs_token) if gvs_token
              return build_live_media(details, payload, hls_url, video_id, url, client, gvs_token)
            end

            formats = formats_from(payload["streamingData"]?, client, bootstrap, gvs_token)
            return build_media(details, payload, formats, video_id, url) unless formats.empty?

            errors << "#{player_client.name}: live stream has no HLS manifest"
            next
          end

          formats = formats_from(payload["streamingData"]?, client, bootstrap, gvs_token)
          if formats.empty?
            errors << "#{player_client.name}: no direct formats; JavaScript challenge support is required"
            next
          end

          return build_media(details, payload, formats, video_id, url)
        rescue ex : Rill::Error
          errors << "#{player_client.name}: #{ex.message}"
        end
      end

      raise MediaUnavailableError.new(url.to_s, errors.uniq.join("; "))
    ensure
      @solver.try(&.close)
      @solver = nil
      @solver_loaded = false
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

    private def live_hls_url(payload : Hash(String, JSON::Any)) : URI?
      streaming = payload["streamingData"]?.try(&.as_h?)
      return nil unless streaming

      HttpUrl.absolute(JsonValue.string(streaming["hlsManifestUrl"]?))
    end

    private def build_live_media(
      details : Hash(String, JSON::Any),
      payload : Hash(String, JSON::Any),
      hls_url : URI,
      video_id : String,
      url : URI,
      client : HTTPClient,
      pot : String? = nil,
    ) : Media
      hls_media = Rill::Extractors::Hls.new.extract(hls_url, client)
      live = hls_media.is_live?
      duration = live ? nil : JsonValue.seconds(details["lengthSeconds"]?)
      formats = hls_media.formats
      if pot
        formats = formats.map { |format| format.with_url(with_pot(format.url, pot)) }
      end

      Media.new(
        id: JsonValue.string(details["videoId"]?) || video_id,
        title: JsonValue.string(details["title"]?) || video_id,
        description: JsonValue.string(details["shortDescription"]?),
        webpage_url: url,
        uploader: JsonValue.string(details["author"]?),
        duration_seconds: duration,
        thumbnail_url: thumbnail_url(details),
        upload_date: upload_date(payload),
        extractor: name,
        formats: formats,
        warnings: hls_media.warnings,
        is_live: live,
      )
    end

    private def watch_page(client : HTTPClient, video_id : String) : Bootstrap
      endpoint = "#{@api_base}/watch?v=#{video_id}&bpctr=9999999999&has_verified=1"
      page_bootstrap(client.get(endpoint, page_headers).body)
    rescue Rill::Error
      Bootstrap.new
    end

    private def page_headers : HTTP::Headers
      headers = HTTP::Headers.new
      headers["User-Agent"] = WATCH_PAGE_USER_AGENT
      headers["Accept-Language"] = "en-US,en;q=0.9"
      headers["Cookie"] = PAGE_COOKIE
      headers
    end

    private def page_bootstrap(body : String) : Bootstrap
      visitor = body.match(/"VISITOR_DATA":"([^"]+)"/) ||
                body.match(/"visitorData":"([^"]+)"/)
      api_key = body.match(/"INNERTUBE_API_KEY":"([^"]+)"/)
      js_url = body.match(/"jsUrl":"([^"]+)"/) ||
               body.match(/"PLAYER_JS_URL":"([^"]+)"/)

      Bootstrap.new(visitor.try(&.[1]), api_key.try(&.[1]), js_url.try(&.[1]))
    end

    private def ensure_visitor_data(client : HTTPClient, bootstrap : Bootstrap) : Bootstrap
      return bootstrap if bootstrap.visitor_data

      visitor = visitor_id(client)
      return bootstrap unless visitor

      Bootstrap.new(visitor, bootstrap.api_key, bootstrap.js_url)
    end

    private def visitor_id(client : HTTPClient) : String?
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
        end
      end

      headers = HTTP::Headers.new
      headers["User-Agent"] = SEARCH_CLIENT.user_agent
      headers["X-YouTube-Client-Name"] = SEARCH_CLIENT.identifier
      headers["X-YouTube-Client-Version"] = SEARCH_CLIENT.version
      headers["Origin"] = @api_base
      headers["Referer"] = "#{@api_base}/"

      endpoint = "#{@api_base}/youtubei/v1/visitor_id?key=#{API_KEY}&prettyPrint=false"
      response = client.post(endpoint, body, headers)
      payload = JSON.parse(response.body)
      context = payload["responseContext"]?.try(&.as_h?)
      JsonValue.string(context.try(&.["visitorData"]?))
    rescue Rill::Error | JSON::ParseException
      nil
    end

    private def web_po_tokens(
      client : HTTPClient,
      video_id : String,
      bootstrap : Bootstrap,
    ) : Tuple(String?, String?)
      endpoint = client.options.po_token_provider
      return {nil, nil} unless endpoint

      provider = PoTokenProvider.new(endpoint)
      player = bootstrap.visitor_data.try { |visitor| provider.token(client, visitor) }
      {player, provider.token(client, video_id)}
    end

    private def player_payload(
      client : HTTPClient,
      player_client : PlayerClient,
      video_id : String,
      bootstrap : Bootstrap,
      url : URI,
      po_token : String? = nil,
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
          if po_token
            json.field "serviceIntegrityDimensions" do
              json.object do
                json.field "poToken", po_token
              end
            end
          end
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

require "./youtube/solver"

require "./youtube/formats"

require "./youtube/playlist"

require "./youtube/channel"

require "./youtube/po_token"
