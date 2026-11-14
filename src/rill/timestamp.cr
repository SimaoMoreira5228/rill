module Rill
  module Timestamp
    extend self

    def clock_seconds(value : String?) : Float64?
      return nil unless value

      total = 0.0
      value.split(':').each do |part|
        number = part.to_f?
        return nil unless number && number.finite? && number >= 0

        total = total * 60 + number
      end

      total
    end

    def iso8601_seconds(value : String?) : Float64?
      return nil unless value

      match = /\AP(?:(\d+)D)?T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?\z/.match(value)
      return nil unless match

      days = match[1]?.try(&.to_f) || 0.0
      hours = match[2]?.try(&.to_f) || 0.0
      minutes = match[3]?.try(&.to_f) || 0.0
      seconds = match[4]?.try(&.to_f) || 0.0

      total = days * 86_400 + hours * 3600 + minutes * 60 + seconds
      total if total > 0
    end
  end
end
