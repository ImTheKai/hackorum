require "rails_helper"

RSpec.describe PatchCi::RepoMaintenance do
  let(:logger)   { Logger.new(File::NULL) }
  let(:importer) { instance_double(CommitImport::Importer, run!: true) }
  let(:now)      { Time.zone.parse("2026-07-28 10:00:00") }

  def result(success, output = "")
    instance_double(PatchBranches::GitRepo::Result, success?: success, output: output)
  end

  def repo(fetch: result(true))
    instance_double(PatchBranches::GitRepo, dir: "/ci/repo").tap do |double|
      allow(double).to receive(:run).with("fetch", "--prune", "--tags", "postgres").and_return(fetch)
    end
  end

  def maintenance(git)
    described_class.new(repo: git, importer_factory: -> { importer }, logger: logger)
  end

  before { allow(AdvisoryLock).to receive(:with_lock).with(CommitImportJob::LOCK_KEY).and_yield }

  it "fetches upstream and imports on the first call" do
    git = repo

    outcome = maintenance(git).call(now: now)

    expect(outcome.ran).to be(true)
    expect(outcome.fetch_error).to be_nil
    expect(outcome.import_error).to be_nil
    expect(outcome.skipped).to be_falsey
    expect(git).to have_received(:run).with("fetch", "--prune", "--tags", "postgres")
    expect(importer).to have_received(:run!).once
  end

  it "does nothing inside the interval" do
    git = repo
    subject = maintenance(git)
    subject.call(now: now)

    outcome = subject.call(now: now + 59.minutes)

    expect(outcome.ran).to be(false)
    expect(importer).to have_received(:run!).once
  end

  it "runs again once the interval has elapsed" do
    git = repo
    subject = maintenance(git)
    subject.call(now: now)

    expect(subject.call(now: now + 61.minutes).ran).to be(true)
    expect(importer).to have_received(:run!).twice
  end

  it "runs again exactly at the interval boundary" do
    git = repo
    subject = maintenance(git)
    subject.call(now: now)

    expect(subject.call(now: now + 1.hour).ran).to be(true)
  end

  it "pings progress once between the fetch and the import" do
    progress = []
    subject = described_class.new(repo: repo, importer_factory: -> { importer },
                                   on_progress: -> { progress << :tick }, logger: logger)

    subject.call(now: now)

    expect(progress).to eq([ :tick ])
  end

  it "does not ping progress when the throttle window has not elapsed" do
    progress = []
    subject = described_class.new(repo: repo, importer_factory: -> { importer },
                                   on_progress: -> { progress << :tick }, logger: logger)
    subject.call(now: now)
    progress.clear

    subject.call(now: now + 1.minute)

    expect(progress).to be_empty
  end

  # the import is worth its seconds even on what we already have, and a
  # network blip must not silently skip an hour of commits
  it "imports even when the fetch failed" do
    outcome = maintenance(repo(fetch: result(false, "no route to host"))).call(now: now)

    expect(outcome.fetch_error).to include("no route to host")
    expect(importer).to have_received(:run!)
  end

  it "collapses a multi-line fetch failure into one line" do
    output = "error: RPC failed\nfatal: the remote end hung up unexpectedly\n"
    outcome = maintenance(repo(fetch: result(false, output))).call(now: now)

    expect(outcome.fetch_error).not_to include("\n")
    expect(outcome.fetch_error).to include("error: RPC failed fatal: the remote end hung up unexpectedly")
  end

  it "reports an import failure without raising" do
    allow(importer).to receive(:run!).and_raise(CommitImport::Error, "corrupt mirror")

    outcome = maintenance(repo).call(now: now)

    expect(outcome.import_error).to include("corrupt mirror")
    expect(outcome.skipped).to be_falsey
  end

  it "treats a held lock as a skip, not an error" do
    allow(AdvisoryLock).to receive(:with_lock).with(CommitImportJob::LOCK_KEY).and_return(nil)

    outcome = maintenance(repo).call(now: now)

    expect(outcome.import_error).to be_nil
    expect(outcome.skipped).to be(true)
    expect(importer).not_to have_received(:run!)
  end

  it "builds the production importer against the repo's own path with fetch disabled" do
    git = repo
    repository_double = instance_double(CommitImport::Repository)
    importer_double = instance_double(CommitImport::Importer, run!: true)

    expect(CommitImport::Repository).to receive(:new)
      .with(path: git.dir, upstream_remote: "postgres").and_return(repository_double)
    expect(CommitImport::Importer).to receive(:new)
      .with(repository: repository_double, fetch: false, logger: logger).and_return(importer_double)

    outcome = described_class.new(repo: git, logger: logger).call(now: now)

    expect(outcome.import_error).to be_nil
  end
end
