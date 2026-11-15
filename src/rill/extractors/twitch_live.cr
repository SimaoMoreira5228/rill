require "http/params"
require "json"
require "uri"

require "../errors"
require "../extractor"
require "../format"
require "../http_url"
require "../json_value"
require "../media"
require "./hls"
require "./twitch/gql"
require "./twitch/usher"

module Rill::Extractors
  class TwitchLive < Extractor
    DEFAULT_USHER_BASE   = "https://usher.ttvnw.net"
    STREAM_METADATA_HASH = "ad022ca32220d5523d03a23cbcb5beaa1e0999889c1f8f78f9f2520dafb5cae6"
    CHANNEL_PATH         = %r{\A/([A-Za-z0-9_]{1,25})/?\z}
    LOGIN                = /\A[A-Za-z0-9_]{1,25}\z/
    TWITCH_HOSTS         = {"twitch.tv", "www.twitch.tv", "go.twitch.tv", "m.twitch.tv"}
    RESERVED_PATHS       = {
      "videos", "directory", "settings", "login", "signup", "subscriptions",
      "inventory", "drops", "wallet", "friends", "search", "downloads", "jobs",
      "turbo", "creatorcamp", "store", "collections", "following", "dashboard",
      "embed", "privacy", "terms", "p",
    }

    private record LiveStream, display_name : String?, stream : Hash(String, JSON::Any)

    def initialize(
      @endpoint : String = TwitchGql::DEFAULT_ENDPOINT,
      @usher_base : String = DEFAULT_USHER_BASE,
    )
      @gql = TwitchGql.new(@endpoint)
    end

    def name : String
      "twitch_live"
    end

    def matches?(url : URI) : Bool
      return false unless url.scheme == "http" || url.scheme == "https"

      !identifier_for(url).nil?
    end

    def extract(url : URI, client : HTTPClient) : Media
      login = identifier_for(url)
      unless login
        raise UnsupportedUrlError.new(url.to_s)
      end

      login = login.downcase
      live = stream_data(client, login, url)
      token = @gql.playback_access_token(client, token_query(login), "streamPlaybackAccessToken")
      playlist = Extractors::Hls.new.extract(usher_url(login, token), client)

      type = JsonValue.string(live.stream["type"]?)
      title = live.display_name || login
      title += " (rerun)" if type == "rerun"

      Media.new(
        id: JsonValue.string(live.stream["id"]?) || login,
        title: title,
        webpage_url: url,
        uploader: live.display_name,
        thumbnail_url: thumbnail_for(login),
        upload_date: upload_date_for(live.stream),
        extractor: name,
        formats: playlist.formats,
        is_live: type == "live",
      )
    end

    private def identifier_for(url : URI) : String?
      host = url.host.try(&.downcase)
      return nil unless host

      if host == "player.twitch.tv"
        return player_identifier(url)
      end

      return nil unless TWITCH_HOSTS.includes?(host)

      login = CHANNEL_PATH.match(url.path).try(&.[1])
      return nil unless login

      login unless RESERVED_PATHS.includes?(login.downcase)
    end

    private def player_identifier(url : URI) : String?
      return nil unless url.path == "/"

      login = HTTP::Params.parse(url.query || "")["channel"]?
      return nil unless login

      login if LOGIN.matches?(login)
    end

    private def stream_data(
      client : HTTPClient,
      login : String,
      url : URI,
    ) : LiveStream
      response = @gql.post(client, metadata_body(login))
      element = response.as_a?.try(&.first?).try(&.as_h?)
      data = element.try(&.["data"]?).try(&.as_h?)
      user = data.try(&.["user"]?).try(&.as_h?)

      unless user
        raise MediaUnavailableError.new(url.to_s, "channel does not exist")
      end

      stream = user["stream"]?.try(&.as_h?)
      unless stream
        raise MediaUnavailableError.new(url.to_s, "channel is not live")
      end

      LiveStream.new(JsonValue.string(user["displayName"]?), stream)
    end

    private def metadata_body(login : String) : String
      JSON.build do |json|
        json.array do
          json.object do
            json.field "operationName", "StreamMetadata"
            json.field "variables" do
              json.object do
                json.field "channelLogin", login
                json.field "includeIsDJ", true
              end
            end
            json.field "extensions" do
              json.object do
                json.field "persistedQuery" do
                  json.object do
                    json.field "version", 1
                    json.field "sha256Hash", STREAM_METADATA_HASH
                  end
                end
              end
            end
          end
        end
      end
    end

    private def token_query(login : String) : String
      String.build do |io|
        io << "{ streamPlaybackAccessToken(channelName: \""
        io << login
        io << "\", params: {platform: \"web\", playerBackend: \"mediaplayer\", "
        io << "playerType: \"site\"}) { value signature } }"
      end
    end

    private def usher_url(login : String, token : TwitchGql::AccessToken) : URI
      Twitch::Usher.url(@usher_base, "api/channel/hls/#{login}.m3u8", token)
    end

    private def thumbnail_for(login : String) : URI?
      HttpUrl.absolute("https://static-cdn.jtvnw.net/previews-ttv/live_user_#{login}-1280x720.jpg")
    end

    private def upload_date_for(stream : Hash(String, JSON::Any)) : String?
      created_at = JsonValue.string(stream["createdAt"]?)
      return nil unless created_at && created_at.size >= 10

      date = created_at[0, 10]
      date if /\A\d{4}-\d{2}-\d{2}\z/.matches?(date)
    end
  end
end
