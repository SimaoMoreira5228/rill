require "http/params"
require "json"
require "set"
require "uri"

require "../../errors"
require "../../format"
require "../../http_client"
require "../../http_url"
require "../../json_value"
require "../../mime_type"
require "./solver"

module Rill::Extractors
  class YouTube < Extractor
    private def formats_from(
      streaming_value : JSON::Any?,
      client : HTTPClient,
      bootstrap : Bootstrap,
    ) : Array(Format)
      streaming = streaming_value.try(&.as_h?)
      return [] of Format unless streaming

      formats = [] of Format
      seen = Set(String).new
      ciphers = [] of Tuple(JSON::Any, String)
      n_challenges = [] of String

      {"formats", "adaptiveFormats"}.each do |key|
        items = streaming[key]?.try(&.as_a?) || [] of JSON::Any

        items.each do |item|
          value = item.as_h?
          next unless value

          if url = HttpUrl.absolute(JsonValue.string(value["url"]?))
            if challenge = n_challenge(url)
              n_challenges << challenge
            end
            add_format(formats, seen, format_from(item, url))
          elsif cipher = JsonValue.string(value["signatureCipher"]?)
            ciphers << {item, cipher}
          end
        end
      end

      unless ciphers.empty? && n_challenges.empty?
        if solver = solver_for(client, bootstrap)
          requests = [] of Solver::Request

          unless ciphers.empty?
            challenges = ciphers.compact_map { |(_, cipher)| cipher_challenge(cipher) }.uniq
            requests << Solver::Request.new("sig", challenges) unless challenges.empty?
          end

          unless n_challenges.empty?
            requests << Solver::Request.new("n", n_challenges.uniq)
          end

          responses = solver.solve(requests)
          signatures = solution_for(responses, requests, "sig")
          nsigs = solution_for(responses, requests, "n")

          ciphers.each do |(item, cipher)|
            if url = resolve_cipher(cipher, signatures)
              add_format(formats, seen, format_from(item, url))
            end
          end

          unless nsigs.empty?
            formats.map! do |format|
              if challenge = n_challenge(format.url)
                if decoded = nsigs[challenge]?
                  format.with_url(replace_n(format.url, decoded))
                else
                  format
                end
              else
                format
              end
            end
          end
        end
      end

      formats
    end

    private def add_format(
      formats : Array(Format),
      seen : Set(String),
      format : Format?,
    ) : Nil
      return unless format
      return if seen.includes?(format.format_id)

      seen << format.format_id
      formats << format
    end

    private def solver_for(client : HTTPClient, bootstrap : Bootstrap) : Solver?
      return @solver if @solver_loaded
      @solver_loaded = true

      path = bootstrap.js_url
      return nil unless path

      path = path.gsub("\\/", "/").gsub("\\u0026", "&")
      url = if path.starts_with?("http://") || path.starts_with?("https://")
              URI.parse(path)
            else
              URI.parse("#{@api_base}#{path.starts_with?("/") ? "" : "/"}#{path}")
            end

      @solver = Solver.new(client.get(url).body)
    rescue Rill::Error | URI::Error | JSON::ParseException
      @solver = nil
    end

    private def n_challenge(url : URI) : String?
      HTTP::Params.parse(url.query || "")["n"]?
    end

    private def cipher_challenge(cipher : String) : String?
      HTTP::Params.parse(cipher)["s"]?
    end

    private def resolve_cipher(
      cipher : String,
      signatures : Hash(String, String),
    ) : URI?
      params = HTTP::Params.parse(cipher)
      url = params["url"]?
      signature = params["s"]?
      parameter = params["sp"]?
      return nil unless url && signature && parameter

      decoded = signatures[signature]?
      return nil unless decoded

      separator = url.includes?('?') ? '&' : '?'
      HttpUrl.absolute("#{url}#{separator}#{parameter}=#{URI.encode_www_form(decoded)}")
    rescue ArgumentError | URI::Error
      nil
    end

    private def replace_n(url : URI, decoded : String) : URI
      params = HTTP::Params.parse(url.query || "")
      params["n"] = decoded
      updated = url.dup
      updated.query = params.to_s
      updated
    end

    private def solution_for(
      responses : Array(Solver::Response),
      requests : Array(Solver::Request),
      type : String,
    ) : Hash(String, String)
      responses.each_with_index do |response, index|
        next unless requests[index]?.try(&.type) == type

        return response.data || {} of String => String
      end

      {} of String => String
    end

    private def format_from(item : JSON::Any, url : URI) : Format?
      value = item.as_h?
      return nil unless value

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
  end
end
