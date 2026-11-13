require "../../spec_helper"
require "../../../src/rill/c_api/memory"

describe Rill::CAPI::Memory do
  it "copies NUL-terminated strings" do
    pointer = Rill::CAPI::Memory.copy_string("hello")
    pointer.null?.should be_false
    pointer[5].should eq(0_u8)
    String.new(pointer).should eq("hello")
  ensure
    Rill::CAPI::Memory.free(pointer.not_nil!) unless pointer.nil? || pointer.null?
  end
end
