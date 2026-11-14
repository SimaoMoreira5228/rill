require "../spec_helper"

describe Rill::DownloadOptions do
  it "uses defaults" do
    options = Rill::DownloadOptions.from_json(nil)

    options.format_id.should be_nil
    options.preference.should eq(Rill::FormatPreference::AudioAndVideo)
    options.overwrite.should be_false
    options.resume.should be_true
    options.media_backend.should eq(Rill::MediaMuxer.backend_from_environment)
  end

  it "parses download and request options" do
    options = Rill::DownloadOptions.from_json(<<-JSON)
      {
        "request": {"user_agent": "test-agent", "retries": 1},
        "format_id": "137",
        "overwrite": true,
        "resume": false,
        "media_backend": "system"
      }
    JSON

    options.request.user_agent.should eq("test-agent")
    options.request.retries.should eq(1)
    options.format_id.should eq("137")
    options.overwrite.should be_true
    options.resume.should be_false
    options.media_backend.should eq(Rill::MediaMuxer::Backend::System)
  end

  it "maps role flags to a preference" do
    options = Rill::DownloadOptions.from_json(%({"audio_only": true}))
    options.preference.should eq(Rill::FormatPreference::AudioOnly)
  end

  it "rejects conflicting selection" do
    expect_raises(Rill::InvalidOptionsError, /cannot be combined/) do
      Rill::DownloadOptions.from_json(%({"audio_only": true, "video_only": true}))
    end

    expect_raises(Rill::InvalidOptionsError, /cannot be combined/) do
      Rill::DownloadOptions.from_json(%({"format_id": "137", "audio_only": true}))
    end
  end

  it "rejects unknown or malformed options" do
    expect_raises(Rill::InvalidOptionsError, /unknown download option/) do
      Rill::DownloadOptions.from_json(%({"nope": true}))
    end

    expect_raises(Rill::InvalidOptionsError, /must be a boolean/) do
      Rill::DownloadOptions.from_json(%({"overwrite": "yes"}))
    end

    expect_raises(Rill::InvalidOptionsError, /not valid JSON/) do
      Rill::DownloadOptions.from_json("not json")
    end
  end
end
