require "rails_helper"

RSpec.describe PatchCi::ResultRefPruner do
  around do |example|
    Dir.mktmpdir do |dir|
      @work_dir = File.join(dir, "origin-work")
      @origin_dir = File.join(dir, "origin.git")
      @local_dir = File.join(dir, "local")
      example.run
    end
  end

  let(:fixture) { GitFixtureRepo.new(@work_dir) }
  let(:origin) { PatchBranches::GitRepo.new(@work_dir) }
  let(:remote) { PatchBranches::GitRepo.new(@origin_dir) }
  let(:repo) { PatchBranches::GitRepo.new(@local_dir) }
  let(:pruner) { described_class.new(repo) }

  def ci_ref(name, content = %({"ok":true}))
    blob = origin.run!("hash-object", "-w", "--stdin", stdin: content).stdout.strip
    tree = origin.run!("mktree", stdin: "100644 blob #{blob}\tresult.json\n").stdout.strip
    commit = origin.run!("commit-tree", tree, "-m", "result").stdout.strip
    origin.run!("update-ref", "refs/hackorum-ci/#{name}", commit)
  end

  def clone_and_fetch
    fixture.mirror_to(@origin_dir)
    out, err, status = Open3.capture3("git", "clone", "--quiet", @origin_dir, @local_dir)
    raise "clone failed: #{err}#{out}" unless status.success?
    expect(PatchCi::ResultRefs.new(repo).fetch!).to be_success
  end

  def ingested_run(run_id, **attrs)
    create(:patch_ci_run, github_run_id: run_id, status: "success",
                          payload: { "status" => "success" },
                          completed_at: 30.days.ago, **attrs)
  end

  def ref_present?(git_repo, name)
    !git_repo.rev_parse("refs/hackorum-ci/#{name}").nil?
  end

  before { fixture.commit(subject: "base", files: { "README" => "x\n" }) }

  it "deletes remote and local refs for ingested old runs" do
    ci_ref(41)
    clone_and_fetch
    ingested_run(41)

    expect(pruner.prune!).to eq(1)
    expect(ref_present?(remote, 41)).to be(false)
    expect(ref_present?(repo, 41)).to be(false)
  end

  it "keeps refs without a run row and junk ref names" do
    ci_ref(42)
    ci_ref("garbage")
    clone_and_fetch

    expect(pruner.prune!).to eq(0)
    expect(ref_present?(remote, 42)).to be(true)
    expect(ref_present?(remote, "garbage")).to be(true)
  end

  it "keeps the ref while the run is not terminal" do
    ci_ref(43)
    clone_and_fetch
    ingested_run(43, status: "running", completed_at: nil)

    expect(pruner.prune!).to eq(0)
    expect(ref_present?(remote, 43)).to be(true)
  end

  it "keeps the ref while the payload was not ingested" do
    ci_ref(44)
    clone_and_fetch
    ingested_run(44, payload: nil)

    expect(pruner.prune!).to eq(0)
    expect(ref_present?(remote, 44)).to be(true)
  end

  it "keeps the ref while the row only holds an ingest_error marker" do
    ci_ref(50)
    clone_and_fetch
    ingested_run(50, status: "infra_error", payload: { "ingest_error" => "malformed json" })

    expect(pruner.prune!).to eq(0)
    expect(ref_present?(remote, 50)).to be(true)
  end

  it "keeps the ref while another attempt of the same run is live" do
    ci_ref(51)
    clone_and_fetch
    ingested_run(51)
    create(:patch_ci_run, github_run_id: 51, run_attempt: 2, status: "running",
                          payload: nil, completed_at: nil)

    expect(pruner.prune!).to eq(0)
    expect(ref_present?(remote, 51)).to be(true)
  end

  it "keeps the ref inside the retention window" do
    ci_ref(45)
    clone_and_fetch
    ingested_run(45, completed_at: 1.day.ago)

    expect(pruner.prune!).to eq(0)
    expect(ref_present?(remote, 45)).to be(true)
  end

  it "respects the limit" do
    ci_ref(46)
    ci_ref(47)
    clone_and_fetch
    ingested_run(46)
    ingested_run(47)

    expect(pruner.prune!(limit: 1)).to eq(1)
    expect([ ref_present?(remote, 46), ref_present?(remote, 47) ]).to contain_exactly(true, false)
  end

  it "keeps the local ref when the remote delete fails" do
    ci_ref(48)
    clone_and_fetch
    ingested_run(48)
    repo.run!("remote", "set-url", "origin", "/nonexistent/remote.git")

    expect(pruner.prune!).to eq(0)
    expect(ref_present?(repo, 48)).to be(true)
  end

  it "does nothing without any result refs" do
    clone_and_fetch
    ingested_run(49)

    expect(pruner.prune!).to eq(0)
  end
end
