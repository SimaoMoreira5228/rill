require "../spec_helper"

describe Rill::JsonValue do
  it "reads strings from scalars and string arrays" do
    Rill::JsonValue.string(JSON.parse(%("text"))).should eq("text")
    Rill::JsonValue.string(JSON.parse("42")).should eq("42")
    Rill::JsonValue.string(JSON.parse("4.5")).should eq("4.5")
    Rill::JsonValue.string(JSON.parse(%([null, "first", "second"]))).should eq("first")
    Rill::JsonValue.string(JSON.parse("true")).should be_nil
    Rill::JsonValue.string(nil).should be_nil
  end

  it "reads integers and numbers, including numeric strings" do
    Rill::JsonValue.integer(JSON.parse(%("42"))).should eq(42_i64)
    Rill::JsonValue.integer(JSON.parse("42.5")).should be_nil
    Rill::JsonValue.number(JSON.parse(%("42.5"))).should eq(42.5)
    Rill::JsonValue.number(JSON.parse("42")).should eq(42.0)
  end

  it "applies media field bounds" do
    Rill::JsonValue.dimension(JSON.parse("720")).should eq(720)
    Rill::JsonValue.dimension(JSON.parse("0")).should be_nil
    Rill::JsonValue.dimension(JSON.parse("100001")).should be_nil
    Rill::JsonValue.positive_number(JSON.parse("0")).should be_nil
    Rill::JsonValue.seconds(JSON.parse("-1")).should be_nil
  end
end
