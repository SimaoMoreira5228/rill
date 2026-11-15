require "../../spec_helper"

private def hls_key(iv : Bytes? = nil) : Rill::Hls::Key
  Rill::Hls::Key.new(method: "AES-128", iv: iv)
end

describe Rill::Hls::Decryption do
  it "derives the IV from the media sequence when absent" do
    iv = Rill::Hls::Decryption.iv(hls_key, 1_i64)
    iv.should eq(Bytes[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])

    iv = Rill::Hls::Decryption.iv(hls_key, 0x0102_i64)
    iv.should eq(Bytes[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2])
  end

  it "prefers an explicit IV" do
    explicit = Bytes.new(16, 9_u8)
    Rill::Hls::Decryption.iv(hls_key(explicit), 42_i64).should eq(explicit)
  end

  it "decrypts AES-128 CBC segments" do
    key_bytes = Bytes.new(16) { |index| (index + 1).to_u8 }
    iv = Bytes.new(16) { |index| (index + 20).to_u8 }
    plain = "the quick brown fox jumps over the lazy dog".to_slice

    encryptor = OpenSSL::Cipher.new("aes-128-cbc")
    encryptor.encrypt
    encryptor.key = key_bytes
    encryptor.iv = iv
    ciphertext = encryptor.update(plain) + encryptor.final

    decryptor = Rill::Hls::Decryption.cipher(hls_key(iv), key_bytes, 0_i64)
    decrypted = decryptor.update(ciphertext) + decryptor.final

    decrypted.should eq(plain)
  end
end
