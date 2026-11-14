require "../../spec_helper"

describe Rill::Extractors::YouTube::Solver do
  it "solves a known n challenge" do
    unless ENV["RILL_YOUTUBE_SOLVER_TEST"]?
      pending! "set RILL_YOUTUBE_SOLVER_TEST=1 to run the live player solver"
    end

    player_js = Rill::HTTPClient.new.get(
      "https://www.youtube.com/s/player/5ec65609/player_ias.vflset/en_US/base.js",
    ).body
    solver = Rill::Extractors::YouTube::Solver.new(player_js)

    begin
      response = solver.solve([
        Rill::Extractors::YouTube::Solver::Request.new("n", ["IMKPt9L6DXEYGGRzJ"]),
      ]).first

      response.type.should eq("result")
      response.data.not_nil!["IMKPt9L6DXEYGGRzJ"].should eq("zL66zSisCR_I4g")
    ensure
      solver.close
    end
  end
end
