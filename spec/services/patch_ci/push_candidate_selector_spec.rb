require "rails_helper"

RSpec.describe PatchCi::PushCandidateSelector do
  around do |example|
    Dir.mktmpdir { |dir| @repo_dir = File.join(dir, "repo"); example.run }
  end

  let(:fixture) { GitFixtureRepo.new(@repo_dir) }
  let(:repo) { PatchBranches::GitRepo.new(fixture.path) }
  let(:selector) { described_class.new(repo) }

  def ac_init
    "AC_INIT([PostgreSQL], [20devel], [pgsql-bugs@lists.postgresql.org])\n"
  end

  def branch_with_commit(name, files: { "a.c" => "v2\n" })
    base = fixture.commit(subject: "base #{name}", files: { "configure.ac" => ac_init })
    fixture.commit(subject: "patch #{name}", files: files)
    fixture.create_branch(name)
    fixture.checkout("master")
    base
  end

  def record(branch_name, base_sha, **attrs)
    topic = create(:topic)
    message = create(:message, topic: topic)
    create(:patch_branch, topic: topic, message: message, branch_name: branch_name,
                          base_sha: base_sha, status: "applied", **attrs)
  end

  it "returns an applied branch that exists and has commits" do
    base = branch_with_commit("t1_1")
    row = record("t1_1", base)

    expect(selector.eligible.map(&:id)).to eq([ row.id ])
  end

  it "skips a row whose branch is missing from the repo" do
    row = record("t404_1", fixture.commit(subject: "base"))

    expect(selector.eligible).to be_empty
    expect(selector.rejections[row.id]).to eq("branch missing from repo")
  end

  it "rejects a row with no base sha" do
    branch_with_commit("t9_1")
    row = record("t9_1", nil)

    expect(selector.eligible).to be_empty
    expect(selector.rejections[row.id]).to eq("base sha missing")
  end

  it "skips a branch identical to its base" do
    base = fixture.commit(subject: "base", files: { "configure.ac" => ac_init })
    fixture.create_branch("t2_1")
    record("t2_1", base)

    expect(selector.eligible).to be_empty
  end

  it "rejects a branch touching .github and gives a reason" do
    base = branch_with_commit("t3_1", files: { ".github/workflows/evil.yml" => "x\n" })
    row = record("t3_1", base)

    expect(selector.eligible).to be_empty
    expect(selector.rejections[row.id]).to eq("patchset touches .github/")
  end

  it "skips rows already pushed at the same head" do
    base = branch_with_commit("t4_1")
    record("t4_1", base, pushed_at: Time.current, ci_status: "pushed_awaiting_ci")

    expect(selector.eligible).to be_empty
  end

  it "includes already-pushed rows when forced" do
    base = branch_with_commit("t5_1")
    row = record("t5_1", base, pushed_at: Time.current, ci_status: "success")

    expect(described_class.new(repo, force: true).eligible.map(&:id)).to eq([ row.id ])
  end

  it "keeps only the latest message per topic, by timestamp not by id" do
    base = branch_with_commit("t6_1")
    branch_with_commit("t6_2")
    topic = create(:topic)
    # recent gets the LOWER id, old gets the HIGHER id: only created_at can pick right
    recent = create(:message, topic: topic, created_at: 1.hour.ago)
    old = create(:message, topic: topic, created_at: 2.days.ago)
    latest = create(:patch_branch, topic: topic, message: recent, branch_name: "t6_2",
                                   base_sha: base, status: "applied")
    create(:patch_branch, topic: topic, message: old, branch_name: "t6_1",
                          base_sha: base, status: "applied")

    expect(selector.eligible.map(&:id)).to eq([ latest.id ])
  end

  it "rejects when the diff against base cannot be computed" do
    branch_with_commit("t8_1")
    row = record("t8_1", "1234567890abcdef1234567890abcdef12345678")

    expect(selector.eligible).to be_empty
    expect(selector.rejections[row.id]).to eq("cannot inspect changed paths")
  end

  it "rejects an unsupported era with a reason" do
    base = fixture.commit(subject: "base",
                          files: { "configure.in" => "AC_INIT([PostgreSQL], [16beta1])\n" })
    fixture.commit(subject: "patch", files: { "a.c" => "v2\n" })
    fixture.create_branch("t7_1")
    fixture.checkout("master")
    row = record("t7_1", base)

    expect(selector.eligible).to be_empty
    expect(selector.rejections[row.id]).to eq("no era image for pg16")
  end
end
