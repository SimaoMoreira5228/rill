require "json"

module Rill
  module JsonValue
    extend self

    def string(value : JSON::Any?) : String?
      return nil unless value

      if text = value.as_s?
        text
      elsif array = value.as_a?
        array.each do |item|
          found = item.as_s?
          return found if found
        end
        nil
      elsif integer = value.as_i64?
        integer.to_s
      elsif float = value.as_f?
        float.to_s
      end
    end

    def integer(value : JSON::Any?) : Int64?
      return nil unless value

      if text = value.as_s?
        text.to_i64?
      else
        value.as_i64?
      end
    end

    def number(value : JSON::Any?) : Float64?
      return nil unless value

      parsed = if text = value.as_s?
                 text.to_f?
               elsif integer = value.as_i64?
                 integer.to_f
               elsif float = value.as_f?
                 float
               end

      parsed if parsed && parsed.finite?
    end

    def positive_number(value : JSON::Any?) : Float64?
      parsed = number(value)
      parsed if parsed && parsed > 0
    end

    def dimension(value : JSON::Any?) : Int32?
      parsed = integer(value)
      return nil unless parsed && 0 < parsed <= 100_000

      parsed.to_i32
    end

    def seconds(value : JSON::Any?) : Float64?
      parsed = number(value)
      parsed if parsed && parsed >= 0
    end
  end
end
