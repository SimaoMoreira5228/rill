require "./format"

module Rill
  struct DownloadPlan
    getter stream : Format
    getter audio : Format?

    def initialize(@stream : Format, @audio : Format? = nil)
    end

    def formats : Array(Format)
      if audio = @audio
        [@stream, audio]
      else
        [@stream]
      end
    end

    def container : String?
      @stream.container || @audio.try(&.container)
    end

    def requires_merge? : Bool
      !@audio.nil?
    end
  end
end
