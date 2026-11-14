require "../../javascript"

module Rill::Extractors
  class YouTube
    class Solver
      LIB  = {{ read_file("#{__DIR__}/yt.solver.lib.min.js") }}
      CORE = {{ read_file("#{__DIR__}/yt.solver.core.min.js") }}

      struct Request
        getter type : String
        getter challenges : Array(String)

        def initialize(@type : String, @challenges : Array(String))
        end
      end

      struct Response
        getter type : String
        getter data : Hash(String, String)?
        getter error : String?

        def initialize(
          @type : String,
          @data : Hash(String, String)? = nil,
          @error : String? = nil,
        )
        end
      end

      @engine : Rill::JavaScript::Engine
      @player_js : String

      def initialize(@player_js : String)
        @engine = Rill::JavaScript::Engine.new(
          memory_limit: 256_i64 * 1024 * 1024,
          timeout: 30.seconds,
        )

        @engine.eval(LIB)
        @engine.eval("Object.assign(globalThis, lib);")
        @engine.eval(CORE)
        @engine.eval(<<-JS)
          function rillSolve(payload) {
            const input = JSON.parse(payload);
            input.type = 'player';
            return JSON.stringify(jsc(input));
          }
        JS
      end

      def solve(requests : Array(Request)) : Array(Response)
        payload = JSON.build do |json|
          json.object do
            json.field "player", @player_js
            json.field "requests" do
              json.array do
                requests.each do |request|
                  json.object do
                    json.field "type", request.type
                    json.field "challenges" do
                      json.array do
                        request.challenges.each { |challenge| json.string(challenge) }
                      end
                    end
                  end
                end
              end
            end
          end
        end

        parse_output(JSON.parse(@engine.call("rillSolve", payload)))
      end

      def close : Nil
        @engine.close
      end

      def finalize
        close
      end

      private def parse_output(value : JSON::Any) : Array(Response)
        responses = value["responses"]?.try(&.as_a?) || [] of JSON::Any

        responses.map do |item|
          hash = item.as_h?
          type = hash.try(&.["type"]?).try(&.as_s?) || "error"

          if type == "result"
            data = {} of String => String
            if values = hash.try(&.["data"]?).try(&.as_h?)
              values.each do |key, result|
                text = result.as_s?
                data[key] = text if text
              end
            end
            Response.new("result", data)
          else
            Response.new("error", nil, hash.try(&.["error"]?).try(&.as_s?))
          end
        end
      end
    end
  end
end
