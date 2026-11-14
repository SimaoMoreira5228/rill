require "spec"

require "../src/rill"
require "./support/test_http_server"
require "./support/downloader_helpers"

def fixture_path(*parts : String) : String
  File.join(__DIR__, "fixtures", *parts)
end

def fixture(*parts : String) : String
  File.read(fixture_path(*parts))
end
