require "../spec_helper"

describe Rill::Redaction do
  it "redacts sensitive query values" do
    value = Rill::Redaction.url("https://example.com/v?pot=secret&sig=abc&n=123&x=1")

    value.should contain("pot=REDACTED")
    value.should contain("sig=REDACTED")
    value.should contain("n=REDACTED")
    value.should contain("x=1")
    value.should_not contain("secret")
  end

  it "redacts URLs in error messages" do
    error = Rill::HTTPError.new(
      URI.parse("https://example.com/v?pot=secret&sig=abc"),
      HTTP::Status.new(403),
      "",
    )

    error.message.not_nil!.should contain("pot=REDACTED")
    error.message.not_nil!.should_not contain("secret")
  end
end
