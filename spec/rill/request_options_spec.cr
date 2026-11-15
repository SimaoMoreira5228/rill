require "../spec_helper"

describe Rill::RequestOptions do
  it "uses explicit defaults" do
    options = Rill::RequestOptions.new

    options.user_agent.should eq(Rill::RequestOptions::DEFAULT_USER_AGENT)
    options.connect_timeout.should eq(15.seconds)
    options.read_timeout.should eq(30.seconds)
    options.max_redirects.should eq(10)
    options.retries.should eq(2)
    options.retry_delay.should eq(1.second)
    options.max_response_bytes.should eq(16_i64 * 1024 * 1024)
    options.cookies.should be_empty
    options.po_token_provider.should be_nil
  end

  it "parses every supported option" do
    options = Rill::RequestOptions.from_json(<<-JSON)
      {
        "user_agent": "test-agent",
        "headers": {
          "X-One": "first",
          "X-Many": ["a", "b"]
        },
        "cookies": {"session": "abc"},
        "connect_timeout_seconds": 5,
        "read_timeout_seconds": 2.5,
        "retry_delay_seconds": 0,
        "max_redirects": 3,
        "retries": 4,
        "max_response_bytes": 1024,
        "po_token_provider": "https://provider.example/pot"
      }
    JSON

    options.user_agent.should eq("test-agent")
    options.headers.get("X-One").should eq(["first"])
    options.headers.get("X-Many").should eq(["a", "b"])
    options.cookies["session"].should eq("abc")
    options.connect_timeout.should eq(5.seconds)
    options.read_timeout.should eq(2.5.seconds)
    options.retry_delay.should eq(Time::Span.zero)
    options.max_redirects.should eq(3)
    options.retries.should eq(4)
    options.max_response_bytes.should eq(1024)
    options.po_token_provider.should eq("https://provider.example/pot")
  end

  it "rejects malformed JSON" do
    expect_raises(Rill::InvalidOptionsError, /not valid JSON/) do
      Rill::RequestOptions.from_json("nope")
    end
  end

  it "rejects non-object JSON" do
    expect_raises(Rill::InvalidOptionsError, /must be a JSON object/) do
      Rill::RequestOptions.from_json("[]")
    end
  end

  it "rejects unknown options" do
    expect_raises(Rill::InvalidOptionsError, /unknown option bogus/) do
      Rill::RequestOptions.from_json(%({"bogus": true}))
    end
  end

  it "rejects wrong option types" do
    expect_raises(Rill::InvalidOptionsError, /user_agent must be a string/) do
      Rill::RequestOptions.from_json(%({"user_agent": 1}))
    end

    expect_raises(Rill::InvalidOptionsError, /max_redirects must be an integer/) do
      Rill::RequestOptions.from_json(%({"max_redirects": 1.5}))
    end

    expect_raises(Rill::InvalidOptionsError, /cookies must be a JSON object/) do
      Rill::RequestOptions.from_json(%({"cookies": []}))
    end
  end

  it "rejects invalid header and cookie values" do
    expect_raises(Rill::InvalidOptionsError, /header X-Test must be a string/) do
      Rill::RequestOptions.from_json(%({"headers": {"X-Test": 1}}))
    end

    expect_raises(Rill::InvalidOptionsError, /cookie session must be a string/) do
      Rill::RequestOptions.from_json(%({"cookies": {"session": 1}}))
    end
  end

  it "rejects values outside their allowed range" do
    expect_raises(Rill::InvalidOptionsError, /read_timeout_seconds must be greater than zero/) do
      Rill::RequestOptions.from_json(%({"read_timeout_seconds": 0}))
    end

    expect_raises(Rill::InvalidOptionsError, /retries must not be negative/) do
      Rill::RequestOptions.from_json(%({"retries": -1}))
    end

    expect_raises(Rill::InvalidOptionsError, /max_response_bytes must be positive/) do
      Rill::RequestOptions.from_json(%({"max_response_bytes": 0}))
    end

    expect_raises(Rill::InvalidOptionsError, /max_redirects is out of range/) do
      Rill::RequestOptions.from_json(%({"max_redirects": 999999999999}))
    end
  end
end
