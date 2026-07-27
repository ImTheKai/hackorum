require "rails_helper"

RSpec.describe PatchCi::EraDetector do
  around do |example|
    Dir.mktmpdir { |dir| @dir = File.join(dir, "repo"); example.run }
  end

  let(:fixture) { GitFixtureRepo.new(@dir) }
  let(:repo) { PatchBranches::GitRepo.new(fixture.path) }
  let(:detector) { described_class.new(repo) }

  def ac_init(version)
    "AC_INIT([PostgreSQL], [#{version}], [pgsql-bugs@lists.postgresql.org])\n"
  end

  it "reads the major from configure.ac" do
    sha = fixture.commit(subject: "modern", files: { "configure.ac" => ac_init("19devel") })
    expect(detector.major_for(sha)).to eq(19)
  end

  it "falls back to configure.in on old trees" do
    sha = fixture.commit(subject: "old", files: { "configure.in" => ac_init("10beta1") })
    expect(detector.major_for(sha)).to eq(10)
  end

  it "collapses 9.x onto 9" do
    sha = fixture.commit(subject: "ancient", files: { "configure.in" => ac_init("9.6beta1") })
    expect(detector.major_for(sha)).to eq(9)
  end

  it "returns nil when there is no configure file" do
    sha = fixture.commit(subject: "empty", files: { "README" => "hi\n" })
    expect(detector.major_for(sha)).to be_nil
  end

  it "returns nil when AC_INIT is unparseable" do
    sha = fixture.commit(subject: "weird", files: { "configure.ac" => "AC_INIT([PostgreSQL])\n" })
    expect(detector.major_for(sha)).to be_nil
  end

  it "only calls majors with a built era image supported" do
    expect(detector.supported?(20)).to be(true)
    expect(detector.supported?(16)).to be(true)
  end

  # no family covers these, so there is nothing to enable: an 8.x tree predates
  # the oldest era image, and the next major has no family until one is added
  it "does not support a major no family serves" do
    expect(detector.supported?(8)).to be(false)
    expect(detector.supported?(21)).to be(false)
  end

  it "reads a sha's configure only once" do
    sha = fixture.commit(subject: "modern", files: { "configure.ac" => ac_init("19devel") })
    expect(detector.major_for(sha)).to eq(19)

    expect(repo).not_to receive(:run)
    expect(detector.major_for(sha)).to eq(19)
  end

  it "caches per sha, not per detector" do
    modern = fixture.commit(subject: "modern", files: { "configure.ac" => ac_init("19devel") })
    old = fixture.commit(subject: "old", files: { "configure.ac" => ac_init("10beta1") })

    expect(detector.major_for(modern)).to eq(19)
    expect(detector.major_for(old)).to eq(10)
    expect(detector.major_for(modern)).to eq(19)
  end

  it "retries a sha whose configure could not be read" do
    sha = fixture.commit(subject: "modern", files: { "configure.ac" => ac_init("19devel") })
    locked = PatchBranches::GitRepo::Result.new("", "fatal: index locked", 128)
    allow(repo).to receive(:run).and_return(locked)
    expect(detector.major_for(sha)).to be_nil

    allow(repo).to receive(:run).and_call_original
    expect(detector.major_for(sha)).to eq(19)
  end

  it "returns nil for a blank sha without touching git" do
    expect(repo).not_to receive(:run)
    expect(detector.major_for(nil)).to be_nil
  end
end
