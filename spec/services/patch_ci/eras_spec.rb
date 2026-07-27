require "rails_helper"

RSpec.describe PatchCi::Eras do
  before { described_class.reset! }
  after { described_class.reset! }

  it "parses every family in eras.yml" do
    names = described_class.families.map(&:name)
    expect(names).to include("stretch", "buster", "bullseye", "bookworm", "trixie")
  end

  it "reads majors as integers" do
    stretch = described_class.families.find { |family| family.name == "stretch" }
    expect(stretch.majors).to eq([ 9, 10, 11 ])
  end

  it "maps a major to its family" do
    expect(described_class.name_for(15)).to eq("bullseye")
    expect(described_class.name_for(20)).to eq("trixie")
  end

  it "returns nil for a major no family serves" do
    expect(described_class.family_for(7)).to be_nil
    expect(described_class.name_for(7)).to be_nil
  end

  it "reports a disabled family's majors as not enabled" do
    expect(described_class.enabled?(12)).to be(false)
    expect(described_class.enabled?(16)).to be(false)
  end

  it "reports an enabled family's majors as enabled" do
    expect(described_class.enabled?(20)).to be(true)
  end

  # the drift guard: this fails if eras.yml and SUPPORTED_MAJORS disagree, which
  # is the whole reason this class reads the file instead of duplicating it
  it "maps every supported major to exactly one family" do
    PatchCi::EraDetector::SUPPORTED_MAJORS.each do |major|
      matches = described_class.families.select { |family| family.majors.include?(major) }
      expect(matches.size).to eq(1), "major #{major} maps to #{matches.map(&:name).inspect}"
    end
  end

  it "memoizes the parse" do
    expect(YAML).to receive(:safe_load_file).once.and_call_original
    described_class.families
    described_class.families
  end

  it "freezes families deeply, so the process-wide memo can't be mutated" do
    family = described_class.families.first
    expect { family.majors << 99 }.to raise_error(FrozenError)
    expect { family.name = "mutated!" }.to raise_error(FrozenError)
  end
end
