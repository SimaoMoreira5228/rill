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

module Rill::Extractors
  class TwitchVod < Extractor
    DEFAULT_USHER_BASE = "https://usher.ttvnw.net"
    VIDEOS_PATH        = %r{\A/videos/(\d+)/?\z}
    CHANNEL_VOD_PATH   = %r{\A/[^/]+/v(?:ideo)?/(\d+)/?\z}
    TWITCH_HOSTS       = {"twitch.tv", "www.twitch.tv", "go.twitch.tv", "m.twitch.tv"}

    private record AccessToken, value : String, signature : String

    def initialize(
      @endpoint : String = TwitchGql::DEFAULT_ENDPOINT,
      @usher_base : String = DEFAULT_USHER_BASE,
    )
      @gql = TwitchGql.new(@endpoint)
    end

    def name : String
      "twitch_vod"
    end

    def matches?(url : URI) : Bool
      return false unless url.scheme == "http" || url.scheme == "https"

      !identifier_for(url).nil?
    end

    def extract(url : URI, client : HTTPClient) : Media
      video_id = identifier_for(url)
      unless video_id
        raise UnsupportedUrlError.new(url.to_s)
      end

      video = video_data(client, video_id, url)
      token = access_token(client, video_id, url)
      playlist = Extractors::Hls.new.extract(usher_url(video_id, token), client)

      Media.new(
        id: video_id,
        title: JsonValue.string(video["title"]?) || "Untitled Broadcast",
        description: JsonValue.string(video["description"]?),
        webpage_url: url,
        uploader: uploader_for(video),
        duration_seconds: JsonValue.seconds(video["lengthSeconds"]?),
        thumbnail_url: thumbnail_for(video),
        upload_date: upload_date_for(video),
        extractor: name,
        formats: playlist.formats,
      )
    end

    private def identifier_for(url : URI) : String?
      host = url.host.try(&.downcase)
      return nil unless host

      if host == "player.twitch.tv"
        return player_identifier(url)
      end

      return nil unless TWITCH_HOSTS.includes?(host)

      VIDEOS_PATH.match(url.path).try(&.[1]) ||
        CHANNEL_VOD_PATH.match(url.path).try(&.[1])
    end

    private def player_identifier(url : URI) : String?
      return nil unless url.path == "/"

      video = HTTP::Params.parse(url.query || "")["video"]?
      return nil unless video

      video = video.lchop('v')
      video if /\A\d+\z/.matches?(video)
    end

    private def video_data(
      client : HTTPClient,
      video_id : String,
      url : URI,
    ) : Hash(String, JSON::Any)
      response = @gql.post(client, metadata_body(video_id))
      element = response.as_a?.try(&.first?).try(&.as_h?)
      data = element.try(&.["data"]?).try(&.as_h?)
      video = data.try(&.["video"]?).try(&.as_h?)

      unless video
        raise MediaUnavailableError.new(url.to_s, "video is unavailable")
      end

      video
    end

    private def metadata_body(video_id : String) : String
      JSON.build do |json|
        json.array do
          json.object do
            json.field "operationName", "VideoMetadata"
            json.field "variables" do
              json.object do
                json.field "channelLogin", ""
                json.field "videoID", video_id
              end
            end
            json.field "extensions" do
              json.object do
                json.field "persistedQuery" do
                  json.object do
                    json.field "version", 1
                    json.field "sha256Hash",
                      "45111672eea2e507f8ba44d101a61862f9c56b11dee09a15634cb75cb9b9084d"
                  end
                end
              end
            end
          end
        end
      end
    end

    private def access_token(
      client : HTTPClient,
      video_id : String,
      url : URI,
    ) : AccessToken
      response = @gql.post(client, token_body(video_id))
      data = response.as_h?.try(&.["data"]?).try(&.as_h?)
      token = data.try(&.["videoPlaybackAccessToken"]?).try(&.as_h?)

      value = JsonValue.string(token.try(&.["value"]?))
      signature = JsonValue.string(token.try(&.["signature"]?))
      unless value && signature
        raise MediaUnavailableError.new(url.to_s, "video access token is unavailable")
      end

      AccessToken.new(value, signature)
    end

    private def token_body(video_id : String) : String
      query = String.build do |io|
        io << "{ videoPlaybackAccessToken(id: \""
        io << video_id
        io << "\", params: {platform: \"web\", playerBackend: \"mediaplayer\", "
        io << "playerType: \"site\"}) { value signature } }"
      end

      JSON.build do |json|
        json.object do
          json.field "query", query
        end
      end
    end

    private def usher_url(video_id : String, token : AccessToken) : URI
      params = HTTP::Params.new
      params["allow_source"] = "true"
      params["allow_audio_only"] = "true"
      params["allow_spectre"] = "true"
      params["p"] = Random.rand(1_000_000..10_000_000).to_s
      params["platform"] = "web"
      params["player"] = "twitchweb"
      params["supported_codecs"] = "av1,h265,h264"
      params["playlist_include_framerate"] = "true"
      params["sig"] = token.signature
      params["token"] = token.value

      URI.parse("#{@usher_base}/vod/#{video_id}.m3u8?#{params}")
    end

    private def uploader_for(video : Hash(String, JSON::Any)) : String?
      owner = video["owner"]?.try(&.as_h?)

      JsonValue.string(owner.try(&.["displayName"]?)) ||
        JsonValue.string(owner.try(&.["login"]?))
    end

    private def thumbnail_for(video : Hash(String, JSON::Any)) : URI?
      value = JsonValue.string(video["previewThumbnailURL"]?)
      return nil unless value

      HttpUrl.absolute(value.gsub(/\d+x\d+(?=\.\w+)/, "0x0"))
    end

    private def upload_date_for(video : Hash(String, JSON::Any)) : String?
      published = JsonValue.string(video["publishedAt"]?)
      return nil unless published && published.size >= 10

      date = published[0, 10]
      date if /\A\d{4}-\d{2}-\d{2}\z/.matches?(date)
    end
  end
end
