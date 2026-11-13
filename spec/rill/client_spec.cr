require "file_utils"

require "../spec_helper"

module SessionSpecExtractor
  class Cached < Rill::Extractor
    class_property base_url : String = ""

    def name : String
      "session"
    end

    def matches?(url : URI) : Bool
      true
    end

    def extract(url : URI, client : Rill::HTTPClient) : Rill::Media
      client.get("#{self.class.base_url}/set")

      Rill::Media.new(
        title: "cached",
        webpage_url: url,
        extractor: name,
        formats: [
          Rill::Format.new(
            format_id: "file",
            url: URI.parse("#{self.class.base_url}/file"),
          ),
        ],
      )
    end
  end
end

describe Rill::Client do
  it "shares cookies between extraction and download" do
    server = TestHTTPServer.new
    server.on("/set") do |_, response|
      response.headers.add("Set-Cookie", "session=abc; Path=/")
      response.print("set")
    end
    server.on("/file") do |_, response|
      body = "downloaded"
      response.content_length = body.bytesize
      response.print(body)
    end
    server.start

    directory = File.join(Dir.tempdir, "rill-client-spec-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(directory)

    begin
      SessionSpecExtractor::Cached.base_url = server.url
      registry = Rill::ExtractorRegistry.new
      registry.register(SessionSpecExtractor::Cached)
      client = Rill::Client.new(registry: registry)

      media = client.extract("https://example.com/watch")
      target = Path.new(directory) / "file.bin"
      client.download(media.formats.first, target)

      File.read(target).should eq("downloaded")
      file_request = server.requests.find { |request| request.path == "/file" }.not_nil!
      file_request.headers["Cookie"].should eq("session=abc")
    ensure
      FileUtils.rm_rf(directory)
      server.close
    end
  end
end
