require "../spec_helper"

describe Rill::Timestamp do
  it "parses seconds and clock text" do
    Rill::Timestamp.clock_seconds("213").should eq(213.0)
    Rill::Timestamp.clock_seconds("3:33").should eq(213.0)
    Rill::Timestamp.clock_seconds("1:02:03.5").should eq(3723.5)
  end

  it "rejects malformed or negative values" do
    Rill::Timestamp.clock_seconds(nil).should be_nil
    Rill::Timestamp.clock_seconds("").should be_nil
    Rill::Timestamp.clock_seconds("1:x3").should be_nil
    Rill::Timestamp.clock_seconds("-1:00").should be_nil
  end
end
