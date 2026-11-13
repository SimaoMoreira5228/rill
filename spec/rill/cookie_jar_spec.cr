require "../spec_helper"

private def cookie_headers(*values : String) : HTTP::Headers
  headers = HTTP::Headers.new
  values.each do |value|
    headers.add("Set-Cookie", value)
  end
  headers
end

describe Rill::CookieJar do
  it "stores host-only cookies" do
    jar = Rill::CookieJar.new
    jar.add(cookie_headers("session=abc; Path=/"), URI.parse("https://example.com/login"))

    cookies = jar.cookies_for(URI.parse("https://example.com/other"))
    cookies.size.should eq(1)
    cookies.first.name.should eq("session")
    cookies.first.value.should eq("abc")

    jar.cookies_for(URI.parse("https://sub.example.com/")).should be_empty
    jar.cookies_for(URI.parse("https://other.com/")).should be_empty
  end

  it "honors domain cookies" do
    jar = Rill::CookieJar.new
    jar.add(
      cookie_headers("shared=yes; Domain=example.com; Path=/"),
      URI.parse("https://sub.example.com/login"),
    )

    jar.cookies_for(URI.parse("https://example.com/")).should_not be_empty
    jar.cookies_for(URI.parse("https://other.example.com/")).should_not be_empty
    jar.cookies_for(URI.parse("https://notexample.com/")).should be_empty
  end

  it "scopes cookies by path" do
    jar = Rill::CookieJar.new
    jar.add(
      cookie_headers("admin=yes; Path=/admin"),
      URI.parse("https://example.com/admin/login"),
    )

    jar.cookies_for(URI.parse("https://example.com/admin/panel")).should_not be_empty
    jar.cookies_for(URI.parse("https://example.com/public")).should be_empty
    jar.cookies_for(URI.parse("https://example.com/administrator")).should be_empty
  end

  it "does not send secure cookies over HTTP" do
    jar = Rill::CookieJar.new
    jar.add(
      cookie_headers("secure=yes; Secure; Path=/"),
      URI.parse("https://example.com/login"),
    )

    jar.cookies_for(URI.parse("https://example.com/")).should_not be_empty
    jar.cookies_for(URI.parse("http://example.com/")).should be_empty
  end

  it "rejects Domain attributes that do not cover the response host" do
    jar = Rill::CookieJar.new

    jar.add(
      cookie_headers("steal=yes; Domain=victim.com; Path=/"),
      URI.parse("https://attacker.com/"),
    )
    jar.add(
      cookie_headers("suffix=yes; Domain=com; Path=/"),
      URI.parse("https://attacker.com/"),
    )

    jar.cookies_for(URI.parse("https://victim.com/")).should be_empty
    jar.cookies_for(URI.parse("https://example.com/")).should be_empty
  end

  it "deletes a stored cookie when an expired one arrives" do
    jar = Rill::CookieJar.new
    jar.add(cookie_headers("session=abc; Path=/"), URI.parse("https://example.com/login"))
    jar.cookies_for(URI.parse("https://example.com/")).should_not be_empty

    jar.add(cookie_headers("session=; Max-Age=0; Path=/"), URI.parse("https://example.com/logout"))
    jar.cookies_for(URI.parse("https://example.com/")).should be_empty
  end

  it "ignores malformed Set-Cookie headers" do
    jar = Rill::CookieJar.new
    jar.add(cookie_headers("broken; Max-Age=not-a-number"), URI.parse("https://example.com/"))

    jar.cookies_for(URI.parse("https://example.com/")).should be_empty
  end

  it "ignores expired cookies" do
    jar = Rill::CookieJar.new
    jar.add(
      cookie_headers("old=yes; Max-Age=0"),
      URI.parse("https://example.com/login"),
    )

    jar.cookies_for(URI.parse("https://example.com/")).should be_empty
  end
end

describe Rill::HTTPClient do
  it "sends cookies set by an earlier response" do
    server = TestHTTPServer.new
    server.on("/login") do |_, response|
      response.headers.add("Set-Cookie", "session=abc; Path=/")
      response.status = :found
      response.headers["Location"] = "/home"
    end
    server.on("/home") { |_, response| response.print("home") }
    server.start

    begin
      response = Rill::HTTPClient.new.get("#{server.url}/login")
      response.body.should eq("home")

      home_request = server.requests.find { |request| request.path == "/home" }.not_nil!
      home_request.headers["Cookie"].should eq("session=abc")
    ensure
      server.close
    end
  end

  it "orders same-name cookies by path specificity" do
    server = TestHTTPServer.new
    server.on("/set") do |_, response|
      response.headers.add("Set-Cookie", "id=root; Path=/")
      response.headers.add("Set-Cookie", "id=admin; Path=/admin")
      response.print("set")
    end
    server.on("/admin/page") { |_, response| response.print("ok") }
    server.start

    begin
      client = Rill::HTTPClient.new
      client.get("#{server.url}/set")
      client.get("#{server.url}/admin/page")

      request = server.requests.find { |item| item.path == "/admin/page" }.not_nil!
      request.headers["Cookie"].should eq("id=admin; id=root")
    ensure
      server.close
    end
  end

  it "keeps cookies across requests on the same client" do
    server = TestHTTPServer.new
    server.on("/set") do |_, response|
      response.headers.add("Set-Cookie", "token=xyz; Path=/")
      response.print("set")
    end
    server.on("/check") { |_, response| response.print("ok") }
    server.start

    begin
      client = Rill::HTTPClient.new
      client.get("#{server.url}/set")
      client.get("#{server.url}/check")

      check_request = server.requests.find { |request| request.path == "/check" }.not_nil!
      check_request.headers["Cookie"].should eq("token=xyz")
    ensure
      server.close
    end
  end
end
