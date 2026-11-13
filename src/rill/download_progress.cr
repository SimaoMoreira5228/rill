module Rill
  struct DownloadProgress
    getter downloaded_bytes : Int64
    getter total_bytes : Int64?

    def initialize(@downloaded_bytes : Int64, @total_bytes : Int64? = nil)
    end

    def fraction : Float64?
      total = @total_bytes
      return nil unless total && total > 0

      (downloaded_bytes.to_f / total).clamp(0.0, 1.0)
    end
  end
end
