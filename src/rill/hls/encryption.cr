require "../errors"
require "./playlist"

module Rill::Hls
  module Encryption
    extend self

    def validate(playlist : MediaPlaylist) : Nil
      playlist.segments.each do |segment|
        key = segment.key
        next unless key

        unless key.method == "AES-128" && key.identity?
          raise UnsupportedManifestError.new(
            "HLS encryption #{key.method}/#{key.key_format} is not supported",
          )
        end

        unless key.url
          raise UnsupportedManifestError.new("HLS AES-128 key has no URI")
        end
      end
    end
  end
end
