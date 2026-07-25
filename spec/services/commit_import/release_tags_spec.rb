require "rails_helper"

RSpec.describe CommitImport::Importer, "release tags" do
  around do |example|
    Dir.mktmpdir("commit-import") do |dir|
      @tmp = dir
      example.run
    end
  end

  def fixture_repo
    @fixture_repo ||= GitFixtureRepo.new(File.join(@tmp, "source"))
  end

  def importer
    described_class.new(repository: CommitImport::Repository.new(path: fixture_repo.path), fetch: false)
  end

  it "records tags and assigns the earliest containing release" do
    first = fixture_repo.commit(subject: "first", date: "2026-01-01T00:00:00+00:00")
    fixture_repo.tag("REL_18_4")
    second = fixture_repo.commit(subject: "second", date: "2026-02-01T00:00:00+00:00")
    fixture_repo.tag("REL_18_5")

    importer.run!

    expect(ReleaseTag.pluck(:name, :version)).to contain_exactly([ "REL_18_4", "18.4" ], [ "REL_18_5", "18.5" ])
    expect(Commit.find_by(sha: first).released_in).to eq("18.4")
    expect(Commit.find_by(sha: second).released_in).to eq("18.5")
    expect(Commit.find_by(sha: first).released_at).to eq(Time.zone.parse("2026-01-01T00:00:00+00:00"))
  end

  it "leaves unreleased commits NULL" do
    fixture_repo.commit(subject: "first", date: "2026-01-01T00:00:00+00:00")
    fixture_repo.tag("REL_18_4")
    unreleased = fixture_repo.commit(subject: "later", date: "2026-02-01T00:00:00+00:00")

    importer.run!

    expect(Commit.find_by(sha: unreleased).released_in).to be_nil
  end

  it "backfills commits already stored when a new tag appears" do
    sha = fixture_repo.commit(subject: "first", date: "2026-01-01T00:00:00+00:00")
    importer.run!
    expect(Commit.find_by(sha: sha).released_in).to be_nil

    fixture_repo.tag("REL_19_BETA1")
    importer.run!

    expect(Commit.find_by(sha: sha).released_in).to eq("19beta1")
  end

  it "never overwrites an assigned release" do
    sha = fixture_repo.commit(subject: "first", date: "2026-01-01T00:00:00+00:00")
    fixture_repo.tag("REL_18_4")
    importer.run!
    fixture_repo.tag("REL_18_5")

    importer.run!

    expect(Commit.find_by(sha: sha).released_in).to eq("18.4")
  end

  it "records but ignores tags that do not normalize" do
    sha = fixture_repo.commit(subject: "first")
    fixture_repo.tag("REL_18_STABLE")

    importer.run!

    expect(ReleaseTag.find_by(name: "REL_18_STABLE").version).to be_nil
    expect(Commit.find_by(sha: sha).released_in).to be_nil
  end

  it "skips tags already recorded" do
    fixture_repo.commit(subject: "first")
    fixture_repo.tag("REL_18_4")
    importer.run!

    expect { importer.run! }.not_to change(ReleaseTag, :count)
  end

  it "does not let a newer major's tag steal shared history from a stable-branch backport" do
    shared = fixture_repo.commit(subject: "shared ancestor", date: "2026-01-01T00:00:00+00:00")
    fixture_repo.create_branch("REL_18_STABLE")

    master_only = fixture_repo.commit(subject: "master goes on", date: "2026-03-01T00:00:00+00:00")
    fixture_repo.tag("REL_19_BETA1")

    fixture_repo.checkout("REL_18_STABLE")
    backport = fixture_repo.commit(subject: "backport fix", date: "2026-04-01T00:00:00+00:00")
    fixture_repo.tag("REL_18_5")

    importer.run!

    expect(Commit.find_by(sha: shared).released_in).to eq("19beta1")
    expect(Commit.find_by(sha: master_only).released_in).to eq("19beta1")
    expect(Commit.find_by(sha: backport).released_in).to eq("18.5")
  end
end
