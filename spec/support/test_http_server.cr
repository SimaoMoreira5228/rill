require "http/server"
require "socket"

class TestHTTPServer
  alias Handler = Proc(HTTP::Request, HTTP::Server::Response, Nil)

  getter url : String
  getter requests = [] of HTTP::Request

  @port : Int32
  @server : HTTP::Server

  def initialize
    @handlers = {} of String => Handler

    @server = HTTP::Server.new do |context|
      request = context.request
      @requests << request

      handler = @handlers[request.path]?
      if handler
        handler.call(request, context.response)
      else
        context.response.status = :not_found
        context.response.print "not found"
      end
    end

    address = @server.bind_tcp("127.0.0.1", 0)
    @port = address.port
    @url = "http://127.0.0.1:#{@port}"
  end

  def on(path : String, &handler : Handler) : Nil
    @handlers[path] = handler
  end

  def start : Nil
    spawn { @server.listen }
    wait_until_listening
  end

  def close : Nil
    @server.close
  end

  private def wait_until_listening : Nil
    100.times do
      begin
        TCPSocket.new("127.0.0.1", @port).close
        return
      rescue Socket::Error
        sleep 5.milliseconds
      end
    end

    raise "test HTTP server did not start"
  end
end
