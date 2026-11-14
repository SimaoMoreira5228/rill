require "uri"

require "./errors"
require "./mime_type"

module Rill::SegmentAssembly
  enum Family
    MpegTs
    FragmentedMp4
    Webm
    Adts
    Mp3
  end

  FRAGMENTED_EXTENSIONS = {
    "m4s", "mp4", "m4a", "m4v", "cmfv", "cmfa",
  }

  def self.for_hls(map_url : URI?, extensions : Array(String)) : Family
    unique = extensions.map(&.downcase).uniq

    if map_url
      unless unique.all? { |extension| extension.empty? || FRAGMENTED_EXTENSIONS.includes?(extension) }
        raise UnsupportedManifestError.new("HLS segments are not a supported fragmented MP4 layout")
      end

      return Family::FragmentedMp4
    end

    case unique
    when ["ts"]
      Family::MpegTs
    when ["aac"]
      Family::Adts
    when ["mp3"]
      Family::Mp3
    else
      raise UnsupportedManifestError.new(
        "HLS segment concatenation is not verified for #{unique.inspect}",
      )
    end
  end

  def self.for_dash(mime : MimeType, has_init : Bool) : Family
    case mime.subtype
    when "mp4", "m4a", "m4v"
      unless has_init
        raise UnsupportedManifestError.new("DASH fragmented MP4 needs an initialization segment")
      end

      Family::FragmentedMp4
    when "webm"
      unless has_init
        raise UnsupportedManifestError.new("DASH WebM needs an initialization segment")
      end

      Family::Webm
    when "mp2t"
      Family::MpegTs
    when "aac"
      Family::Adts
    when "mpeg"
      Family::Mp3
    else
      raise UnsupportedManifestError.new(
        "DASH segment concatenation is not verified for #{mime.type}/#{mime.subtype}",
      )
    end
  end
end
