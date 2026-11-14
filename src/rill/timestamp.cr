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
  end
end
