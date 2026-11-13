require "c/stdlib"

module Rill::CAPI::Memory
  extend self

  def copy_string(value : String) : UInt8*
    size = value.bytesize + 1
    pointer = LibC.malloc(size).as(UInt8*)
    return Pointer(UInt8).null if pointer.null?

    pointer.copy_from(value.to_unsafe, value.bytesize)
    pointer[value.bytesize] = 0_u8
    pointer
  end

  def copy_c_string(value : UInt8*) : UInt8*
    size = LibC.strlen(value).to_i32 + 1
    copy_bytes(value, size)
  end

  def copy_bytes(source : UInt8*, size : Int32) : UInt8*
    pointer = LibC.malloc(size).as(UInt8*)
    return Pointer(UInt8).null if pointer.null?

    pointer.copy_from(source, size)
    pointer
  end

  def free(value : UInt8*) : Nil
    LibC.free(value) unless value.null?
  end
end
