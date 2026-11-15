require "../../playlist"
require "../../http_client"
require "../../errors"
require "../../json_value"

module Rill::Extractors
  class YouTube < Extractor
    CHANNEL_TABS = {
      "featured", "videos", "shorts", "streams", "playlists",
      "community", "channels", "about", "search",
    }

    private record ChannelPath, path : String, tab : String

    private def channel_path_for(url : URI) : ChannelPath?
      host = url.host.try(&.downcase)
      return nil unless host && HOSTS.includes?(host)

      path = url.path
      return nil unless path.starts_with?("/@") ||
                        path.starts_with?("/channel/") ||
                        path.starts_with?("/user/") ||
                        path.starts_with?("/c/")

      segments = path.split('/').reject(&.empty?)
      return nil if segments.empty?

      tab = "videos"
      last = segments.last
      if CHANNEL_TABS.includes?(last)
        return nil unless last == "videos" || last == "streams" || last == "shorts"

        tab = last
        segments.pop
      end

      return nil if segments.empty?

      ChannelPath.new("/" + segments.join('/'), tab)
    end

    private def extract_channel(
      url : URI,
      channel_path : String,
      tab : String,
      client : HTTPClient,
    ) : Playlist
      endpoint = "#{@api_base}#{channel_path}/#{tab}"
      body = client.get(endpoint, page_headers).body
      data = yt_initial_data(body, url)
      bootstrap = page_bootstrap(body)

      metadata = channel_metadata(data)
      channel_id = channel_id(metadata) || channel_path
      entries = [] of PlaylistEntry
      seen = Set(String).new

      collect_playlist_entries(data, entries, seen)
      token = playlist_continuation(data["contents"]?)
      tokens = Set(String).new

      while token && tokens.add?(token)
        page = browse_continuation(client, token, bootstrap)
        collect_playlist_entries(page, entries, seen)
        token = playlist_continuation(page)
      end

      if entries.empty?
        raise MediaUnavailableError.new(url.to_s, "channel has no accessible videos")
      end

      Playlist.new(
        title: JsonValue.string(metadata.try(&.["title"]?)) || channel_path,
        webpage_url: url,
        extractor: name,
        entries: entries,
        id: channel_id,
        description: JsonValue.string(metadata.try(&.["description"]?)),
      )
    end

    private def yt_initial_data(body : String, url : URI) : JSON::Any
      marker = "var ytInitialData = "
      index = body.index(marker)

      unless index
        marker = "ytInitialData = "
        index = body.index(marker)
      end

      unless index
        raise MediaUnavailableError.new(url.to_s, "channel page has no initial data")
      end

      start = body.index('{', index)
      unless start
        raise MediaUnavailableError.new(url.to_s, "channel page has no initial data")
      end

      depth = 0
      in_string = false
      escaped = false
      finish = nil

      body.each_char_with_index do |char, position|
        next if position < start

        if in_string
          if escaped
            escaped = false
          elsif char == '\\'
            escaped = true
          elsif char == '"'
            in_string = false
          end
        else
          case char
          when '"'
            in_string = true
          when '{'
            depth += 1
          when '}'
            depth -= 1
            if depth == 0
              finish = position + 1
              break
            end
          end
        end
      end

      unless finish
        raise MediaUnavailableError.new(url.to_s, "channel page has incomplete initial data")
      end

      JSON.parse(body[start...finish])
    rescue JSON::ParseException
      raise MediaUnavailableError.new(url.to_s, "channel page has invalid initial data")
    end

    private def channel_metadata(data : JSON::Any) : Hash(String, JSON::Any)?
      find_renderer(data, "channelMetadataRenderer")
    end

    private def channel_id(metadata : Hash(String, JSON::Any)?) : String?
      JsonValue.string(metadata.try(&.["externalId"]?)) ||
        JsonValue.string(metadata.try(&.["channelId"]?))
    end

    private def find_renderer(value : JSON::Any, name : String) : Hash(String, JSON::Any)?
      if hash = value.as_h?
        if renderer = hash[name]?.try(&.as_h?)
          return renderer
        end

        hash.each_value do |child|
          if found = find_renderer(child, name)
            return found
          end
        end
      elsif array = value.as_a?
        array.each do |child|
          if found = find_renderer(child, name)
            return found
          end
        end
      end

      nil
    end
  end
end
