require "../spec_helper"

describe Rill::OutputFileName do
  it "removes path separators and invalid characters" do
    name = Rill::OutputFileName.from_title("../evil/na:me?", "mp4")

    name.should eq("_evil_na_me_.mp4")
    name.includes?('/').should be_false
    name.includes?('\\').should be_false
  end

  it "strips leading and trailing dots and spaces" do
    Rill::OutputFileName.from_title("  .hidden name.  ", "mp3").should eq("hidden name.mp3")
  end

  it "falls back for empty titles" do
    Rill::OutputFileName.from_title("...").should eq("download")
  end

  it "avoids duplicate extensions" do
    Rill::OutputFileName.from_title("clip.mp4", "mp4").should eq("clip.mp4")
  end

  it "prefixes Windows reserved names" do
    Rill::OutputFileName.from_title("CON").should eq("_CON")
    Rill::OutputFileName.from_title("nul", "txt").should eq("_nul.txt")
  end

  it "truncates long titles on UTF-8 boundaries" do
    name = Rill::OutputFileName.from_title("é" * 400, "mp4")

    name.bytesize.should be <= Rill::OutputFileName::MAX_BYTES
    name.valid_encoding?.should be_true
    name.ends_with?(".mp4").should be_true
  end

  it "keeps resolved paths inside the output directory" do
    directory = Path.new("/tmp/rill-output")
    path = Rill::OutputFileName.resolve(directory, "clip", "mp4")

    path.should eq(Path.new("/tmp/rill-output/clip.mp4"))
  end

  it "rejects traversal in resolved file names" do
    expect_raises(Rill::InvalidOutputPathError) do
      Rill::OutputFileName.resolve_path("/tmp/rill-output", "../escape.mp4")
    end
  end
end
