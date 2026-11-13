require "../spec_helper"

private def http_client(
  retries : Int32 = 0,
  retry_delay : Time::Span = Time::Span.zero,
  max_redirects : Int32 = 10,
  max_response_bytes : Int64 = 1_000_000,
  read_timeout : Time::Span = 1.second,
) : Rill::HTTPClient
  options = Rill::RequestOptions.new
  options.retries = retries
  options.retry_delay = retry_delay
  options.max_redirects = max_redirects
  options.max_response_bytes = max_response_bytes
  options.read_timeout = read_timeout
  Rill::HTTPClient.new(options)
end

describe Rill::HTTPClient do
  it "sends default request headers" do
    server = TestHTTPServer.new
    server.on("/") { |_, response| response.print("ok") }
    server.start

    begin
      response = http_client.get("#{server.url}/")
      response.body.should eq("ok")

      request = server.requests.first
      request.headers["User-Agent"].should eq(Rill::RequestOptions::DEFAULT_USER_AGENT)
      request.headers["Accept"].should eq("*/*")
    ensure
      server.close
    end
  end

  it "sends configured headers and cookies" do
    server = TestHTTPServer.new
    server.on("/") { |_, response| response.print("ok") }
    server.start

    begin
      options = Rill::RequestOptions.new
      options.headers["X-Test"] = "yes"
      options.cookies["session"] = "abc"

      Rill::HTTPClient.new(options).get("#{server.url}/")

      request = server.requests.first
      request.headers["X-Test"].should eq("yes")
      request.headers["Cookie"].should eq("session=abc")
    ensure
      server.close
    end
  end

  it "percent-encodes unsafe request target bytes" do
    server = TestHTTPServer.new
    server.on("/caf%C3%A9") { |_, response| response.print("ok") }
    server.start

    begin
      response = http_client.get("#{server.url}/café")
      response.body.should eq("ok")
      server.requests.first.path.should eq("/caf%C3%A9")
    ensure
      server.close
    end
  end

  it "follows relative redirects" do
    server = TestHTTPServer.new
    server.on("/old") do |_, response|
      response.status = :found
      response.headers["Location"] = "/new"
    end
    server.on("/new") { |_, response| response.print("new") }
    server.start

    begin
      response = http_client.get("#{server.url}/old")
      response.body.should eq("new")
      response.url.path.should eq("/new")
    ensure
      server.close
    end
  end

  it "drops sensitive headers on cross-origin redirects" do
    target = TestHTTPServer.new
    target.on("/landing") { |_, response| response.print("landed") }
    target.start

    source = TestHTTPServer.new
    source.on("/jump") do |_, response|
      response.status = :found
      response.headers["Location"] = "#{target.url}/landing"
    end
    source.start

    begin
      options = Rill::RequestOptions.new
      options.headers["Authorization"] = "Bearer secret"
      options.cookies["session"] = "abc"

      Rill::HTTPClient.new(options).get("#{source.url}/jump")

      request = target.requests.first
      request.headers["Authorization"]?.should be_nil
      request.headers["Cookie"]?.should be_nil
    ensure
      source.close
      target.close
    end
  end

  it "stops after the redirect limit" do
    server = TestHTTPServer.new
    server.on("/loop") do |_, response|
      response.status = :found
      response.headers["Location"] = "/loop"
    end
    server.start

    begin
      client = http_client(max_redirects: 1)
      expect_raises(Rill::TooManyRedirectsError) do
        client.get("#{server.url}/loop")
      end
    ensure
      server.close
    end
  end

  it "raises on unsuccessful responses" do
    server = TestHTTPServer.new
    server.on("/missing") do |_, response|
      response.status = :not_found
      response.print("gone")
    end
    server.start

    begin
      error = expect_raises(Rill::HTTPError) do
        http_client.get("#{server.url}/missing")
      end
      error.status.code.should eq(404)
      error.response_body.should eq("gone")
    ensure
      server.close
    end
  end

  it "rejects bodies above the configured limit" do
    server = TestHTTPServer.new
    server.on("/large") { |_, response| response.print("x" * 100) }
    server.start

    begin
      client = http_client(max_response_bytes: 10)
      expect_raises(Rill::ResponseTooLargeError) do
        client.get("#{server.url}/large")
      end
    ensure
      server.close
    end
  end

  it "retries retryable responses" do
    attempts = 0
    server = TestHTTPServer.new
    server.on("/retry") do |_, response|
      attempts += 1
      if attempts < 3
        response.status = :internal_server_error
        response.print("fail")
      else
        response.print("ok")
      end
    end
    server.start

    begin
      response = http_client(retries: 2).get("#{server.url}/retry")
      response.body.should eq("ok")
      attempts.should eq(3)
    ensure
      server.close
    end
  end

  it "does not retry client errors" do
    attempts = 0
    server = TestHTTPServer.new
    server.on("/missing") do |_, response|
      attempts += 1
      response.status = :not_found
    end
    server.start

    begin
      expect_raises(Rill::HTTPError) do
        http_client(retries: 2).get("#{server.url}/missing")
      end
      attempts.should eq(1)
    ensure
      server.close
    end
  end

  it "enforces the read timeout" do
    server = TestHTTPServer.new
    server.on("/slow") do |_, response|
      sleep 300.milliseconds
      response.print("late")
    end
    server.start

    begin
      client = http_client(read_timeout: 50.milliseconds)
      expect_raises(Rill::NetworkError) do
        client.get("#{server.url}/slow")
      end
    ensure
      server.close
    end
  end

  it "rejects non-HTTP URLs" do
    client = http_client

    expect_raises(Rill::InvalidUrlError) do
      client.get("ftp://example.com/file.mp4")
    end

    expect_raises(Rill::InvalidUrlError) do
      client.get("https:///missing-host")
    end
  end

  it "rejects invalid options" do
    options = Rill::RequestOptions.new
    options.retries = -1

    expect_raises(ArgumentError) do
      Rill::HTTPClient.new(options)
    end
  end
end
