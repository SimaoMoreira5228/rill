require "openssl"

require "../errors"

module Rill::Hls
  class DecryptingWriter < IO
    def initialize(@destination : IO, @cipher : OpenSSL::Cipher)
    end

    def read(slice : Bytes) : Int32
      raise IO::Error.new("decrypting writer is not readable")
    end

    def write(slice : Bytes) : Nil
      @destination.write(@cipher.update(slice))
    rescue ex : OpenSSL::Cipher::Error
      raise ManifestError.new("HLS AES decryption failed: #{ex.message}")
    end

    def finish : Nil
      @destination.write(@cipher.final)
    rescue ex : OpenSSL::Cipher::Error
      raise ManifestError.new("HLS AES decryption failed: #{ex.message}")
    end
  end
end
