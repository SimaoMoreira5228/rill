require "time"

require "./errors"

module Rill
  module JavaScript
    class Error < Rill::Error
    end

    class Engine
      DEFAULT_MEMORY_LIMIT = 64_i64 * 1024 * 1024
      DEFAULT_STACK_SIZE   = 1024_i64 * 1024
      DEFAULT_TIMEOUT      = 5.seconds

      @handle : LibJavaScript::Handle

      def initialize(
        memory_limit : Int64 = DEFAULT_MEMORY_LIMIT,
        stack_size : Int64 = DEFAULT_STACK_SIZE,
        timeout : Time::Span = DEFAULT_TIMEOUT,
      )
        @handle = LibJavaScript.create(
          memory_limit.to_u64,
          stack_size.to_u64,
          timeout.total_milliseconds.to_i64,
        )

        raise Error.new("failed to create JavaScript engine") if @handle.null?
      end

      def eval(source : String) : Nil
        error = Pointer(UInt8).null
        status = LibJavaScript.eval(@handle, source, source.bytesize, pointerof(error))
        raise_error(error) unless status == 0
      end

      def call(function : String, input : String) : String
        result = Pointer(UInt8).null
        error = Pointer(UInt8).null
        status = LibJavaScript.call(
          @handle,
          function,
          function.bytesize,
          input,
          input.bytesize,
          pointerof(result),
          pointerof(error),
        )
        raise_error(error) unless status == 0
        raise Error.new("JavaScript call returned no result") if result.null?

        value = String.new(result)
        LibJavaScript.free_string(result)
        value
      end

      def close : Nil
        return if @handle.null?

        LibJavaScript.destroy(@handle)
        @handle = Pointer(Void).null
      end

      def finalize
        close
      end

      private def raise_error(error : UInt8*) : NoReturn
        message = error.null? ? "JavaScript error" : String.new(error)
        LibJavaScript.free_string(error) unless error.null?
        raise Error.new(message)
      end
    end

    lib LibJavaScript
      alias Handle = Void*

      fun create = rill_js_new(
        memory_limit : LibC::SizeT,
        stack_size : LibC::SizeT,
        timeout_ms : Int64,
      ) : Handle

      fun destroy = rill_js_free(handle : Handle) : Void

      fun eval = rill_js_eval(
        handle : Handle,
        source : UInt8*,
        source_len : LibC::SizeT,
        error : UInt8**,
      ) : Int32

      fun call = rill_js_call(
        handle : Handle,
        function : UInt8*,
        function_len : LibC::SizeT,
        input : UInt8*,
        input_len : LibC::SizeT,
        result : UInt8**,
        error : UInt8**,
      ) : Int32

      fun free_string = rill_js_free_string(value : UInt8*) : Void
    end
  end
end
