require "base64"
require "json"
require "uri"

require "../errors"
require "../extractor"
require "../format"
require "../http_url"
require "../json_value"
require "../media"
require "../playlist"

module Rill::Extractors
  class Mixcloud < Extractor
    DEFAULT_API_BASE = "https://app.mixcloud.com"
    DEFAULT_LIST     = "uploads"
    ISO_DATE         = /\A\d{4}-\d{2}-\d{2}/
    DECRYPTION_KEY   = "IFYOUWANTTHEARTISTSTOGETPAIDDONOTDOWNLOADFROMMIXCLOUD"
    FIELDS           = "name description audioLength publishDate restrictedReason " \
                       "picture(width: 1024, height: 1024) { url } " \
                       "owner { displayName username url } " \
                       "streamInfo { url hlsUrl dashUrl }"

    RESERVED_SLUGS = %w(stream uploads favorites listens playlists)

    CLOUDCAST_PATH = %r{\A/([^/]+)/([^/]+)/?\z}
    USER_LIST_PATH = %r{\A/([^/]+)/(uploads|favorites|listens|stream)/?\z}
    PLAYLIST_PATH  = %r{\A/([^/]+)/playlists/([^/]+)/?\z}
    USER_PATH      = %r{\A/([^/]+)/?\z}

    struct CloudcastRoute
      getter username : String
      getter slug : String

      def initialize(@username : String, @slug : String)
      end
    end

    struct UserRoute
      getter username : String
      getter list : String

      def initialize(@username : String, @list : String)
      end
    end

    struct PlaylistRoute
      getter username : String
      getter slug : String

      def initialize(@username : String, @slug : String)
      end
    end

    alias Route = CloudcastRoute | UserRoute | PlaylistRoute

    def initialize(@api_base : String = DEFAULT_API_BASE)
      @api_base = @api_base.rstrip('/')
    end

    def name : String
      "mixcloud"
    end

    def matches?(url : URI) : Bool
      return false unless url.scheme == "http" || url.scheme == "https"

      case url.host.try(&.downcase)
      when "mixcloud.com", "www.mixcloud.com", "beta.mixcloud.com", "m.mixcloud.com"
        !lookup(url.path).nil?
      else
        false
      end
    end

    def extract(url : URI, client : HTTPClient) : Media | Playlist
      route = lookup(url.path)
      unless route
        raise UnsupportedUrlError.new(url.to_s)
      end

      case route
      when CloudcastRoute
        extract_cloudcast(route, url, client)
      when UserRoute
        extract_user(route, url, client)
      when PlaylistRoute
        extract_playlist(route, url, client)
      else
        raise UnsupportedUrlError.new(url.to_s)
      end
    end

    private def lookup(path : String) : Route?
      if match = PLAYLIST_PATH.match(path)
        return PlaylistRoute.new(match[1], match[2])
      end

      if match = USER_LIST_PATH.match(path)
        return UserRoute.new(match[1], match[2])
      end

      if match = CLOUDCAST_PATH.match(path)
        username = match[1]
        slug = match[2]
        return CloudcastRoute.new(username, slug) unless RESERVED_SLUGS.includes?(slug.downcase)
      end

      match = USER_PATH.match(path)
      return nil unless match

      UserRoute.new(match[1], DEFAULT_LIST)
    end

    private def extract_cloudcast(
      route : CloudcastRoute,
      url : URI,
      client : HTTPClient,
    ) : Media
      cloudcast = fetch_cloudcast(client, route.username, route.slug, url)
      check_restrictions(cloudcast, url)
      title = title(cloudcast, url)
      duration = JsonValue.seconds(cloudcast["audioLength"]?)
      format = audio_format(cloudcast, url, duration)

      Media.new(
        id: "#{route.username}_#{route.slug}",
        title: title,
        description: JsonValue.string(cloudcast["description"]?),
        webpage_url: url,
        uploader: uploader(cloudcast),
        duration_seconds: duration,
        thumbnail_url: thumbnail_url(cloudcast),
        upload_date: upload_date(cloudcast),
        extractor: name,
        formats: [format],
      )
    end

    private def extract_user(
      route : UserRoute,
      url : URI,
      client : HTTPClient,
    ) : Playlist
      entries = [] of PlaylistEntry
      display_name = nil
      biography = nil
      cursor = nil

      loop do
        query = user_query(route.username, route.list, cursor)
        user = graphql_root(client, query, "userLookup", url, "user")
        display_name ||= JsonValue.string(user["displayName"]?)
        biography ||= JsonValue.string(user["biog"]?)
        connection = user[route.list]?.try(&.as_h?)
        break unless connection

        append_cloudcast_entries(connection, entries)
        cursor = next_cursor(connection)
        break unless cursor
      end

      if entries.empty?
        raise MediaUnavailableError.new(url.to_s, "user has no #{route.list} entries")
      end

      title = display_name || route.username

      Playlist.new(
        id: "#{route.username}_#{route.list}",
        title: "#{title} (#{route.list})",
        description: biography,
        webpage_url: url,
        extractor: name,
        entries: entries,
      )
    end

    private def extract_playlist(
      route : PlaylistRoute,
      url : URI,
      client : HTTPClient,
    ) : Playlist
      entries = [] of PlaylistEntry
      playlist_name = nil
      description = nil
      cursor = nil

      loop do
        query = playlist_query(route.username, route.slug, cursor)
        playlist = graphql_root(client, query, "playlistLookup", url, "playlist")
        playlist_name ||= JsonValue.string(playlist["name"]?)
        description ||= JsonValue.string(playlist["description"]?)
        connection = playlist["items"]?.try(&.as_h?)
        break unless connection

        append_playlist_entries(connection, entries)
        cursor = next_cursor(connection)
        break unless cursor
      end

      if entries.empty?
        raise MediaUnavailableError.new(url.to_s, "playlist has no entries")
      end

      title = playlist_name
      unless title
        raise MediaUnavailableError.new(url.to_s, "playlist name is missing")
      end

      Playlist.new(
        id: "#{route.username}_#{route.slug}",
        title: title,
        description: description,
        webpage_url: url,
        extractor: name,
        entries: entries,
      )
    end

    private def fetch_cloudcast(
      client : HTTPClient,
      username : String,
      slug : String,
      url : URI,
    ) : Hash(String, JSON::Any)
      query = cloudcast_query(username, slug)
      graphql_root(client, query, "cloudcastLookup", url, "cloudcast")
    end

    private def graphql_root(
      client : HTTPClient,
      query : String,
      lookup : String,
      url : URI,
      label : String,
    ) : Hash(String, JSON::Any)
      endpoint = URI.parse("#{@api_base}/graphql")
      endpoint.query = URI::Params.encode({"query" => query})
      response = client.get(endpoint)
      payload = JSON.parse(response.body)
      data = payload["data"]?.try(&.as_h?)
      root = data.try { |hash| hash[lookup]?.try(&.as_h?) }
      unless root
        raise MediaUnavailableError.new(url.to_s, "#{label} was not found")
      end

      root
    rescue JSON::ParseException
      raise MediaUnavailableError.new(url.to_s, "GraphQL response is not valid JSON")
    rescue ex : HTTPError
      if ex.status.code == 404
        raise MediaUnavailableError.new(url.to_s, "#{label} was not found")
      end

      raise ex
    end

    private def cloudcast_query(username : String, slug : String) : String
      <<-GRAPHQL
        {
          cloudcastLookup(lookup: {username: #{username.to_json}, slug: #{slug.to_json}}) {
            #{FIELDS}
          }
        }
        GRAPHQL
    end

    private def user_query(username : String, list : String, cursor : String?) : String
      after = cursor_clause(cursor)
      <<-GRAPHQL
        {
          userLookup(lookup: {username: #{username.to_json}}) {
            displayName
            biog
            #{list}(first: 100#{after}) {
              edges {
                node {
                  name
                  slug
                  url
                  owner { username }
                }
              }
              pageInfo {
                endCursor
                hasNextPage
              }
            }
          }
        }
        GRAPHQL
    end

    private def playlist_query(username : String, slug : String, cursor : String?) : String
      after = cursor_clause(cursor)
      <<-GRAPHQL
        {
          playlistLookup(lookup: {username: #{username.to_json}, slug: #{slug.to_json}}) {
            name
            description
            items(first: 100#{after}) {
              edges {
                node {
                  cloudcast {
                    name
                    slug
                    url
                    owner { username }
                  }
                }
              }
              pageInfo {
                endCursor
                hasNextPage
              }
            }
          }
        }
        GRAPHQL
    end

    private def cursor_clause(cursor : String?) : String
      return "" unless cursor

      ", after: #{cursor.to_json}"
    end

    private def append_cloudcast_entries(
      connection : Hash(String, JSON::Any),
      entries : Array(PlaylistEntry),
    ) : Nil
      edges = connection["edges"]?.try(&.as_a?)
      return unless edges

      edges.each do |edge|
        node = edge.as_h?
        next unless node

        cloudcast = node["node"]?.try(&.as_h?)
        next unless cloudcast

        entry = cloudcast_entry(cloudcast)
        entries << entry if entry
      end
    end

    private def append_playlist_entries(
      connection : Hash(String, JSON::Any),
      entries : Array(PlaylistEntry),
    ) : Nil
      edges = connection["edges"]?.try(&.as_a?)
      return unless edges

      edges.each do |edge|
        node = edge.as_h?
        next unless node

        item = node["node"]?.try(&.as_h?)
        next unless item

        cloudcast = item["cloudcast"]?.try(&.as_h?)
        next unless cloudcast

        entry = cloudcast_entry(cloudcast)
        entries << entry if entry
      end
    end

    private def cloudcast_entry(cloudcast : Hash(String, JSON::Any)) : PlaylistEntry?
      cloudcast_url = HttpUrl.absolute(JsonValue.string(cloudcast["url"]?))
      return nil unless cloudcast_url

      slug = JsonValue.string(cloudcast["slug"]?)
      owner = cloudcast["owner"]?.try(&.as_h?)
      owner_username = owner.try { |hash| JsonValue.string(hash["username"]?) }
      id = if slug && owner_username
             "#{owner_username}_#{slug}"
           end

      PlaylistEntry.new(
        url: cloudcast_url,
        title: JsonValue.string(cloudcast["name"]?),
        id: id,
      )
    end

    private def next_cursor(connection : Hash(String, JSON::Any)) : String?
      page_info = connection["pageInfo"]?.try(&.as_h?)
      return nil unless page_info
      return nil unless page_info["hasNextPage"]?.try(&.as_bool?)

      JsonValue.string(page_info["endCursor"]?)
    end

    private def check_restrictions(cloudcast : Hash(String, JSON::Any), url : URI) : Nil
      reason = JsonValue.string(cloudcast["restrictedReason"]?)
      return if reason.nil? || reason.empty?

      case reason
      when "tracklist"
        raise MediaUnavailableError.new(url.to_s, "track is unavailable due to licensing restrictions")
      when "repeat_play"
        raise MediaUnavailableError.new(url.to_s, "play limit was reached")
      else
        raise MediaUnavailableError.new(url.to_s, "track is restricted")
      end
    end

    private def title(cloudcast : Hash(String, JSON::Any), url : URI) : String
      value = JsonValue.string(cloudcast["name"]?)
      unless value
        raise MediaUnavailableError.new(url.to_s, "cloudcast name is missing")
      end

      value
    end

    private def uploader(cloudcast : Hash(String, JSON::Any)) : String?
      owner = cloudcast["owner"]?.try(&.as_h?)
      return nil unless owner

      JsonValue.string(owner["displayName"]?) || JsonValue.string(owner["username"]?)
    end

    private def thumbnail_url(cloudcast : Hash(String, JSON::Any)) : URI?
      picture = cloudcast["picture"]?.try(&.as_h?)
      value = picture.try { |hash| JsonValue.string(hash["url"]?) }
      HttpUrl.absolute(value)
    end

    private def upload_date(cloudcast : Hash(String, JSON::Any)) : String?
      value = JsonValue.string(cloudcast["publishDate"]?)
      return nil unless value
      return value[0, 10] if ISO_DATE.match(value)

      nil
    end

    private def audio_format(
      cloudcast : Hash(String, JSON::Any),
      url : URI,
      duration : Float64?,
    ) : Format
      info = cloudcast["streamInfo"]?.try(&.as_h?)
      if info
        if stream_url = decrypt_stream_url(info["url"]?)
          return stream_format("progressive", FormatProtocol::Http, stream_url, duration)
        end

        if stream_url = decrypt_stream_url(info["hlsUrl"]?)
          return stream_format("hls", FormatProtocol::Hls, stream_url, duration)
        end

        if stream_url = decrypt_stream_url(info["dashUrl"]?)
          return stream_format("dash", FormatProtocol::Dash, stream_url, duration)
        end
      end

      raise MediaUnavailableError.new(url.to_s, "cloudcast has no playable stream")
    end

    private def decrypt_stream_url(value : JSON::Any?) : URI?
      encoded = JsonValue.string(value)
      return nil unless encoded

      cipher = Base64.decode(encoded)
      plain = String.build(cipher.size) do |io|
        cipher.each_with_index do |byte, index|
          io.write_byte(byte ^ DECRYPTION_KEY.to_slice[index % DECRYPTION_KEY.bytesize])
        end
      end

      HttpUrl.absolute(plain)
    rescue Base64::Error
      nil
    end

    private def stream_format(
      format_id : String,
      protocol : FormatProtocol,
      stream_url : URI,
      duration : Float64?,
    ) : Format
      Format.new(
        format_id: format_id,
        url: stream_url,
        kind: FormatKind::Audio,
        protocol: protocol,
        container: "m4a",
        duration_seconds: duration,
      )
    end
  end
end
