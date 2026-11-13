require "./errors"

module Rill
  class Cancellation
    def initialize
      @cancelled = Atomic(Bool).new(false)
    end

    def cancel! : Nil
      @cancelled.set(true)
    end

    def cancelled? : Bool
      @cancelled.get
    end

    def check! : Nil
      raise CancelledError.new if cancelled?
    end
  end
end
