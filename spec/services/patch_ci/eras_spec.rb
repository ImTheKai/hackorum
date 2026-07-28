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

  it "reports an enabled family's majors as enabled" do
    expect(described_class.enabled?(20)).to be(true)
  end

  # every family in eras.yml is enabled today, so the disabled path has no
  # subject left in real data - stub the file rather than lose the coverage,
  # because the next family added starts life as a disabled stub
  it "reports a disabled family's majors as not enabled" do
    allow(YAML).to receive(:safe_load_file).and_return(
      "families" => {
        "jessie" => { "enabled" => false, "majors" => { 8 => nil } },
        "trixie" => { "enabled" => true, "majors" => { 20 => "abc123" } }
      })

    expect(described_class.enabled?(8)).to be(false)
    expect(described_class.enabled?(20)).to be(true)
  end

  # a family with no reference commits is still parsed: a stub has to be
  # readable before it can be filled in
  it "parses a family whose majors have no reference commits" do
    allow(YAML).to receive(:safe_load_file).and_return(
      "families" => { "jessie" => { "enabled" => false, "majors" => { 8 => nil, 9 => nil } } })

    expect(described_class.family_for(8).majors).to eq([ 8, 9 ])
  end

  # supported? has no list of its own to drift from eras.yml - it reads this
  # class. Assert the two agree for every major the file names, so a family
  # enabled here is one the pusher will actually push.
  it "supports exactly the majors of enabled families" do
    detector = PatchCi::EraDetector.new(nil)
    described_class.families.each do |family|
      family.majors.each do |major|
        expect(detector.supported?(major)).to be(family.enabled),
          "pg#{major} (#{family.name}): enabled=#{family.enabled} supported=#{detector.supported?(major)}"
      end
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

  # our config/patch_ci/eras.yml is a copy of postgres-ci's, so it can go stale
  # after a family is added there. Nothing on a CI runner can catch that - the
  # other repo is not checked out - but a dev box with it next to us can, and
  # that is where the copy gets refreshed anyway. Compares what the app reads,
  # not the whole file: base images and runtime packages are postgres-ci's
  # business and change without touching the mapping.
  it "carries the same mapping as postgres-ci's eras.yml" do
    source = [ Rails.root.join("postgres-ci/eras.yml"), Rails.root.join("../postgres-ci/eras.yml") ]
             .find(&:exist?)
    skip "postgres-ci is not checked out next to this repo" unless source

    expect(mapping(described_class::PATH)).to eq(mapping(source)),
      "config/patch_ci/eras.yml drifted, refresh it: cp #{source} #{described_class::PATH}"
  end

  def mapping(path)
    YAML.safe_load_file(path).fetch("families").transform_values do |config|
      { majors: config.fetch("majors").keys.map(&:to_i).sort, enabled: config["enabled"] == true }
    end
  end
end
