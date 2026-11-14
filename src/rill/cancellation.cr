require "./errors"

module Rill
  class Cancellation
    @cancelled : Atomic(Bool)
    @checker : Proc(Bool)?

    def initialize(@checker : Proc(Bool)? = nil)
      @cancelled = Atomic(Bool).new(false)
    end

    def self.watch(&block : -> Bool) : self
      new(block)
    end

    def cancel! : Nil
      @cancelled.set(true)
    end

    def cancelled? : Bool
      checker = @checker
      checker ? checker.call : @cancelled.get
    end

    def check! : Nil
      raise CancelledError.new if cancelled?
    end
  end
end
