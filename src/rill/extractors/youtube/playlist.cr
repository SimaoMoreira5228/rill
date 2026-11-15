require "../../playlist"
require "../../http_client"
require "../../errors"
require "../../json_value"

module Rill::Extractors
  class YouTube < Extractor
    private def playlist_id_for(url : URI) : String?
      host = url.host.try(&.downcase)
      return nil unless host && HOSTS.includes?(host)

      query = HTTP::Params.parse(url.query || "")
      playlist_id = query["list"]?
      return nil unless playlist_id && PLAYLIST_ID.matches?(playlist_id)

      path = url.path
      return playlist_id if path == "/playlist"
      return playlist_id if path == "/watch" && query["v"]?.nil?

      nil
    end

    private def extract_playlist(
      url : URI,
      playlist_id : String,
      client : HTTPClient,
    ) : Playlist
      bootstrap = playlist_bootstrap(client, playlist_id)
      first = browse_playlist(client, playlist_id, bootstrap)
      entries = [] of PlaylistEntry
      seen = Set(String).new

      collect_playlist_entries(first, entries, seen)
      token = playlist_continuation(first["contents"]?)
      tokens = Set(String).new

      while token && tokens.add?(token)
        page = browse_continuation(client, token, bootstrap)
        collect_playlist_entries(page, entries, seen)
        token = playlist_continuation(page)
      end

      if entries.empty?
        raise MediaUnavailableError.new(url.to_s, "playlist has no accessible videos")
      end

      Playlist.new(
        title: playlist_title(first, playlist_id),
        webpage_url: url,
        extractor: name,
        entries: entries,
        id: playlist_id,
        description: playlist_description(first),
      )
    end

    private def playlist_bootstrap(client : HTTPClient, playlist_id : String) : Bootstrap
      endpoint = "#{@api_base}/playlist?list=#{playlist_id}"
      page_bootstrap(client.get(endpoint, page_headers).body)
    rescue Rill::Error
      Bootstrap.new
    end

    private def browse_playlist(
      client : HTTPClient,
      playlist_id : String,
      bootstrap : Bootstrap,
    ) : Hash(String, JSON::Any)
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
          json.field "browseId", "VL#{playlist_id}"
        end
      end

      browse_request(client, body, playlist_id, bootstrap)
    end

    private def browse_continuation(
      client : HTTPClient,
      token : String,
      bootstrap : Bootstrap,
    ) : Hash(String, JSON::Any)
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
          json.field "continuation", token
        end
      end

      browse_request(client, body, nil, bootstrap)
    end

    private def browse_request(
      client : HTTPClient,
      body : String,
      playlist_id : String?,
      bootstrap : Bootstrap,
    ) : Hash(String, JSON::Any)
      headers = HTTP::Headers.new
      headers["User-Agent"] = WATCH_PAGE_USER_AGENT
      headers["X-YouTube-Client-Name"] = SEARCH_CLIENT.identifier
      headers["X-YouTube-Client-Version"] = SEARCH_CLIENT.version
      headers["Origin"] = @api_base
      headers["Referer"] = playlist_id ? "#{@api_base}/playlist?list=#{playlist_id}" : "#{@api_base}/"
      if visitor = bootstrap.visitor_data
        headers["X-Goog-Visitor-Id"] = visitor
      end

      api_key = bootstrap.api_key || API_KEY
      endpoint = "#{@api_base}/youtubei/v1/browse?key=#{api_key}&prettyPrint=false"
      response = client.post(endpoint, body, headers)
      payload = JSON.parse(response.body).as_h?
      unless payload
        raise MediaUnavailableError.new(endpoint, "browse response is not a JSON object")
      end

      payload
    rescue JSON::ParseException
      raise MediaUnavailableError.new(endpoint || @api_base, "browse response is not valid JSON")
    end

    private def collect_playlist_entries(
      value : Hash(String, JSON::Any),
      entries : Array(PlaylistEntry),
      seen : Set(String),
    ) : Nil
      collect_playlist_entries(JSON::Any.new(value), entries, seen)
    end

    private def collect_playlist_entries(
      value : JSON::Any,
      entries : Array(PlaylistEntry),
      seen : Set(String),
    ) : Nil
      if hash = value.as_h?
        if lockup = hash["lockupViewModel"]?.try(&.as_h?)
          append_playlist_entry(entries, seen, playlist_entry(lockup))
        end

        if short = hash["shortsLockupViewModel"]?.try(&.as_h?)
          append_playlist_entry(entries, seen, short_entry(short))
        end

        hash.each_value do |child|
          collect_playlist_entries(child, entries, seen)
        end
      elsif array = value.as_a?
        array.each do |child|
          collect_playlist_entries(child, entries, seen)
        end
      end
    end

    private def append_playlist_entry(
      entries : Array(PlaylistEntry),
      seen : Set(String),
      entry : PlaylistEntry?,
    ) : Nil
      return unless entry
      return unless video_id = entry.id

      entries << entry if seen.add?(video_id)
    end

    private def playlist_entry(lockup : Hash(String, JSON::Any)) : PlaylistEntry?
      content_type = JsonValue.string(lockup["contentType"]?)
      return nil unless content_type == "LOCKUP_CONTENT_TYPE_VIDEO"

      video_id = JsonValue.string(lockup["contentId"]?)
      return nil unless video_id && VIDEO_ID.matches?(video_id)

      metadata = lockup["metadata"]?.try(&.as_h?)
      lockup_metadata = metadata.try(&.["lockupMetadataViewModel"]?).try(&.as_h?)
      title = lockup_metadata.try(&.["title"]?).try(&.as_h?).try(&.["content"]?).try(&.as_s?)

      PlaylistEntry.new(
        url: URI.parse("#{@api_base}/watch?v=#{video_id}"),
        title: title || video_id,
        id: video_id,
      )
    end

    private def short_entry(lockup : Hash(String, JSON::Any)) : PlaylistEntry?
      command = lockup["onTap"]?.try(&.as_h?).try(&.["innertubeCommand"]?).try(&.as_h?)
      endpoint = command.try(&.["reelWatchEndpoint"]?).try(&.as_h?)
      video_id = JsonValue.string(endpoint.try(&.["videoId"]?))
      return nil unless video_id && VIDEO_ID.matches?(video_id)

      overlay = lockup["overlayMetadata"]?.try(&.as_h?)
      title = overlay.try(&.["primaryText"]?).try(&.as_h?).try(&.["content"]?).try(&.as_s?)

      PlaylistEntry.new(
        url: URI.parse("#{@api_base}/watch?v=#{video_id}"),
        title: title || video_id,
        id: video_id,
      )
    end

    private def playlist_title(
      payload : Hash(String, JSON::Any),
      playlist_id : String,
    ) : String
      primary = playlist_primary_info(payload)
      title = primary.try(&.["title"]?).try { |value| text_runs(value) }
      title || "YouTube playlist #{playlist_id}"
    end

    private def playlist_description(payload : Hash(String, JSON::Any)) : String?
      primary = playlist_primary_info(payload)
      primary.try(&.["description"]?).try { |value| text_runs(value) }
    end

    private def playlist_primary_info(
      payload : Hash(String, JSON::Any),
    ) : Hash(String, JSON::Any)?
      sidebar = payload["sidebar"]?.try(&.as_h?)
      items = sidebar.try(&.["playlistSidebarRenderer"]?).try(&.as_h?).try(&.["items"]?).try(&.as_a?)
      return nil unless items

      items.each do |item|
        primary = item.as_h?.try(&.["playlistSidebarPrimaryInfoRenderer"]?).try(&.as_h?)
        return primary if primary
      end

      nil
    end

    private def playlist_continuation(value : Hash(String, JSON::Any)) : String?
      playlist_continuation(JSON::Any.new(value))
    end

    private def playlist_continuation(value : JSON::Any?) : String?
      return nil unless value

      if hash = value.as_h?
        if continuation = hash["continuationCommand"]?.try(&.as_h?)
          if token = JsonValue.string(continuation["token"]?)
            return token
          end
        end

        hash.each_value do |child|
          if token = playlist_continuation(child)
            return token
          end
        end
      elsif array = value.as_a?
        array.each do |child|
          if token = playlist_continuation(child)
            return token
          end
        end
      end

      nil
    end
  end
end
