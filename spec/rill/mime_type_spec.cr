require "../spec_helper"

describe Rill::MimeType do
  it "parses media types and quoted codec lists" do
    mime = Rill::MimeType.parse(%(video/mp4; codecs="avc1.4d401e, mp4a.40.2"))

    mime.type.should eq("video")
    mime.subtype.should eq("mp4")
    mime.container.should eq("mp4")
    mime.video?.should be_true
    mime.audio?.should be_false
    mime.codecs.should eq("avc1.4d401e, mp4a.40.2")
    mime.codec_list.should eq(["avc1.4d401e", "mp4a.40.2"])
  end

  it "maps mpeg audio to mp3" do
    mime = Rill::MimeType.parse("audio/mpeg")

    mime.audio?.should be_true
    mime.container.should eq("mp3")
    mime.audio_codec.should eq("mp3")
  end

  it "uses the subtype as a fallback audio codec" do
    mime = Rill::MimeType.parse("audio/opus")

    mime.container.should eq("opus")
    mime.audio_codec.should eq("opus")
  end

  it "accepts unquoted codecs" do
    mime = Rill::MimeType.parse("audio/webm; codecs=opus")

    mime.codecs.should eq("opus")
    mime.codec_list.should eq(["opus"])
  end

  it "reports malformed values" do
    Rill::MimeType.parse("video").empty?.should be_true
    Rill::MimeType.parse("").empty?.should be_true
  end
end
