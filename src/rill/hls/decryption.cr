require "openssl"

require "./playlist"

module Rill::Hls
  module Decryption
    extend self

    def cipher(key : Key, key_bytes : Bytes, sequence : Int64) : OpenSSL::Cipher
      cipher = OpenSSL::Cipher.new("aes-128-cbc")
      cipher.decrypt
      cipher.key = key_bytes
      cipher.iv = iv(key, sequence)
      cipher
    end

    def iv(key : Key, sequence : Int64) : Bytes
      if iv = key.iv
        return iv
      end

      value = sequence.to_u64
      bytes = Bytes.new(16, 0_u8)
      8.times do |index|
        bytes[15 - index] = ((value >> (8 * index)) & 0xff).to_u8
      end
      bytes
    end
  end
end
