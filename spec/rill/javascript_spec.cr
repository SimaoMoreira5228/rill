require "../spec_helper"

describe Rill::JavaScript::Engine do
  it "evaluates and calls a function" do
    engine = Rill::JavaScript::Engine.new

    begin
      engine.eval("function greet(name){ return 'hello ' + name; }")
      engine.call("greet", "world").should eq("hello world")
    ensure
      engine.close
    end
  end

  it "reports syntax errors" do
    engine = Rill::JavaScript::Engine.new

    begin
      expect_raises(Rill::JavaScript::Error, /SyntaxError/) do
        engine.eval("function (")
      end
    ensure
      engine.close
    end
  end

  it "interrupts long-running scripts" do
    engine = Rill::JavaScript::Engine.new(timeout: 50.milliseconds)

    begin
      expect_raises(Rill::JavaScript::Error, /interrupted/) do
        engine.eval("while (true) {}")
      end
    ensure
      engine.close
    end
  end
end
