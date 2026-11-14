require "../spec_helper"

describe Rill::HttpUrl do
  it "accepts absolute HTTP URLs" do
    Rill::HttpUrl.absolute("https://example.com/clip.mp4").not_nil!.host.should eq("example.com")
    Rill::HttpUrl.absolute("ftp://example.com/clip.mp4").should be_nil
    Rill::HttpUrl.absolute("not a url").should be_nil
    Rill::HttpUrl.absolute(nil).should be_nil
  end

  it "resolves relative URLs against a base" do
    base = URI.parse("https://example.com/media/page.html")

    Rill::HttpUrl.resolve(base, "../clip.mp4").not_nil!.to_s.should eq("https://example.com/clip.mp4")
    Rill::HttpUrl.resolve(base, "javascript:alert(1)").should be_nil
  end
end
