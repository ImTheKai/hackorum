require "rails_helper"

RSpec.describe PatchBranches::ApplyOne do
  include PatchSeriesHelper

  around do |example|
    Dir.mktmpdir do |dir|
      @repo_dir = File.join(dir, "repo")
      @patch_dir = File.join(dir, "patches")
      @wt_dir = File.join(dir, "wt")
      FileUtils.mkdir_p(@patch_dir)
      example.run
    end
  end

  let(:fixture) { GitFixtureRepo.new(@repo_dir) }
  let(:repo) { PatchBranches::GitRepo.new(fixture.path) }

  # created lazily: git worktree add needs at least one commit on master
  def worktree
    @worktree ||= begin
      repo.run!("worktree", "add", "--detach", @wt_dir, "master")
      PatchBranches::GitRepo.new(@wt_dir)
    end
  end

  def apply_one(force: false)
    described_class.new(repo: repo, worktree: worktree, force: force)
  end

  def message_with_patch(patch)
    message = create(:message)
    create(:attachment, message: message, file_name: File.basename(patch),
           body: Base64.encode64(File.binread(patch)))
    message.reload
  end

  def branch_of(message)
    PatchBranch.find_by(message_id: message.id).branch_name
  end

  # commit content on a detached head, off master, then restore master
  def side_commit(from_sha, path, content)
    repo.run!("checkout", "--quiet", "--detach", from_sha)
    File.write(File.join(fixture.path, path), content)
    repo.run!("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-aqm", "side")
    repo.rev_parse("HEAD").tap { repo.run!("checkout", "--quiet", "--force", "master") }
  end

  def ac_init(version)
    "AC_INIT([PostgreSQL], [#{version}], [pgsql-bugs@lists.postgresql.org])\n"
  end

  def capture_error
    begin
      yield
    rescue => e
      return e
    end
    raise "expected the block to raise"
  end

  # everything a bare master-attempt touch is allowed to move
  let(:volatile) { %w[last_master_apply_at master_apply_error updated_at] }

  it "records base metadata and a clean master apply outcome" do
    base = fixture.commit(subject: "base", files: { "a.c" => "v1\n" }, date: Time.current.iso8601)
    patch = generate_patch(fixture.path, base, "a.c", "v2\n", @patch_dir)
    message = message_with_patch(patch)

    outcome, record = apply_one.call(message.id, master_sha: base)

    expect(outcome).to eq(:applied_on_master)
    expect(record).to eq(PatchBranch.find_by(message_id: message.id))
    record.reload
    expect(record.status).to eq("applied")
    expect(record.on_master).to eq(true)
    expect(record.base_committed_at).to be_within(1.minute).of(Time.current)
    expect(record.base_commit_height).to eq(1)
    expect(record.last_master_apply_at).to be_within(1.minute).of(Time.current)
    expect(record.master_apply_error).to be_nil
  end

  it "records the master failure and still applies on the detected base" do
    old_date = "2026-01-01T00:00:00+00:00"
    old = fixture.commit(subject: "old", files: { "a.c" => "v1\n" }, date: old_date)
    fixture.commit(subject: "newer", files: { "a.c" => "v2\n" }, date: "2026-01-05T00:00:00+00:00")
    master_sha = repo.rev_parse("master")
    patch = generate_patch(fixture.path, old, "a.c", "patched\n", @patch_dir)
    message = message_with_patch(patch)
    message.update_column(:created_at, Time.zone.parse("2026-01-10T00:00:00+00:00"))

    outcome, = apply_one.call(message.id, master_sha: master_sha)

    expect(outcome).to eq(:applied_on_base)
    record = PatchBranch.find_by(message_id: message.id)
    expect(record.status).to eq("applied")
    expect(record.on_master).to eq(false)
    expect(record.base_source).to eq("history")
    expect(record.master_apply_error).to be_present
    expect(record.base_committed_at).to eq(Time.zone.parse(old_date))
    expect(record.base_commit_height).to eq(1)
    expect(record.last_master_apply_at).to be_within(1.minute).of(Time.current)
  end

  it "does not claim a master attempt when extraction fails before applying" do
    message = create(:message)
    create(:attachment, message: message, file_name: "screenshot.png", body: Base64.encode64("png"))
    message.reload

    master_sha = fixture.commit(subject: "base", files: { "a.c" => "v1\n" })
    outcome, record = apply_one.call(message.id, master_sha: master_sha)

    expect(outcome).to eq(:extract_failed)
    expect(record.reload.status).to eq("failed")
    expect(record.failure_stage).to eq("extract")
    expect(record.last_master_apply_at).to be_nil
    expect(record.master_apply_error).to be_nil
  end

  # extract and error never get as far as looking at a base, so nulling the
  # row's base columns destroys information the failure has no bearing on -
  # and leaves a row that once applied indistinguishable from one that never
  # had a base at all
  it "keeps the base metadata when extraction fails on a row that already applied" do
    base = fixture.commit(subject: "base", files: { "a.c" => "v1\n" }, date: Time.current.iso8601)
    patch = generate_patch(fixture.path, base, "a.c", "v2\n", @patch_dir)
    message = message_with_patch(patch)
    expect(apply_one.call(message.id, master_sha: base).first).to eq(:applied_on_master)
    before = PatchBranch.find_by(message_id: message.id)

    allow_any_instance_of(PatchBranches::PatchsetExtractor).to receive(:extract)
      .and_raise(PatchBranches::PatchsetExtractor::Error, "no patch attachments")
    outcome, = apply_one.call(message.id, master_sha: base)

    expect(outcome).to eq(:extract_failed)
    expect(before.reload).to have_attributes(
      status: "failed", failure_stage: "extract",
      base_sha: base, base_source: "master", on_master: true,
      base_committed_at: be_present, base_commit_height: be_present
    )
  end

  it "keeps the base metadata when an apply crashes on a row that already applied" do
    base = fixture.commit(subject: "base", files: { "a.c" => "v1\n" }, date: Time.current.iso8601)
    patch = generate_patch(fixture.path, base, "a.c", "v2\n", @patch_dir)
    message = message_with_patch(patch)
    expect(apply_one.call(message.id, master_sha: base).first).to eq(:applied_on_master)
    before = PatchBranch.find_by(message_id: message.id)

    one = apply_one(force: true)
    allow_any_instance_of(PatchBranches::Applier).to receive(:apply).and_raise("boom")
    error = capture_error { one.call(message.id, master_sha: base) }
    expect(one.persist_error(error)).to be_nil

    expect(before.reload).to have_attributes(
      status: "failed", failure_stage: "error",
      base_sha: base, base_committed_at: be_present
    )
  end

  it "skips an unchanged applied row and re-applies it with force" do
    base = fixture.commit(subject: "base", files: { "a.c" => "v1\n" }, date: Time.current.iso8601)
    patch = generate_patch(fixture.path, base, "a.c", "v2\n", @patch_dir)
    message = message_with_patch(patch)
    apply_one.call(message.id, master_sha: base)
    PatchBranch.find_by(message_id: message.id).update!(attempted_at: 1.day.ago)

    expect(apply_one.call(message.id, master_sha: base).first).to eq(:skipped)
    expect(PatchBranch.find_by(message_id: message.id).attempted_at).to be < 1.hour.ago

    expect(apply_one(force: true).call(message.id, master_sha: base).first).to eq(:applied_on_master)
    expect(PatchBranch.find_by(message_id: message.id).attempted_at).to be_within(1.minute).of(Time.current)
  end

  it "records a base detection failure when no commit in history fits" do
    old = fixture.commit(subject: "old", files: { "a.c" => "v1\n" }, date: "2026-06-01T00:00:00+00:00")
    master_sha = fixture.commit(subject: "newer", files: { "a.c" => "v2\n" },
                                date: "2026-06-02T00:00:00+00:00")
    patch = generate_patch(fixture.path, old, "a.c", "patched\n", @patch_dir)
    message = message_with_patch(patch)
    # submitted before every commit: no history window, no dated fallback
    message.update_column(:created_at, Time.zone.parse("2026-01-01T00:00:00+00:00"))

    outcome, record = apply_one.call(message.id, master_sha: master_sha)

    expect(outcome).to eq(:no_base)
    record.reload
    expect(record.status).to eq("failed")
    expect(record.failure_stage).to eq("base_detection")
    expect(record.base_sha).to be_nil
    expect(record.base_committed_at).to be_nil
    expect(record.base_commit_height).to be_nil
    expect(record.conflict_files).to include("a.c")
    expect(record.master_apply_error).to eq(record.failure_reason)
    expect(record.last_master_apply_at).to be_within(1.minute).of(Time.current)
  end

  it "records an apply failure against the detected base" do
    old = fixture.commit(subject: "old", files: { "a.c" => "v1\n" }, date: "2026-06-01T00:00:00+00:00")
    side = side_commit(old, "a.c", "side\n")
    master_sha = fixture.commit(subject: "newer", files: { "a.c" => "v2\n" },
                                date: "2026-06-02T00:00:00+00:00")
    patch = generate_patch(fixture.path, side, "a.c", "sidepatch\n", @patch_dir)
    message = message_with_patch(patch)
    message.update_column(:created_at, Time.zone.parse("2026-06-03T00:00:00+00:00"))

    outcome, record = apply_one.call(message.id, master_sha: master_sha)

    expect(outcome).to eq(:apply_failed)
    record.reload
    expect(record.status).to eq("failed")
    expect(record.failure_stage).to eq("apply")
    expect(record.base_source).to eq("submission_head")
    expect(record.base_sha).to eq(master_sha)
    expect(record.base_commit_height).to eq(2)
    expect(record.conflict_files).to include("a.c")
    expect(record.master_apply_error).to be_present
  end

  it "records the pg major of the base commit" do
    base = fixture.commit(subject: "base",
                          files: { "a.c" => "v1\n", "configure.ac" => ac_init("19devel") })
    patch = generate_patch(fixture.path, base, "a.c", "v2\n", @patch_dir)
    message = message_with_patch(patch)

    apply_one.call(message.id, master_sha: base)

    expect(PatchBranch.find_by(message_id: message.id).pg_major).to eq(19)
  end

  it "records the detected base's major, not master's" do
    old = fixture.commit(subject: "old", date: "2026-01-01T00:00:00+00:00",
                         files: { "a.c" => "v1\n", "configure.ac" => ac_init("19devel") })
    fixture.commit(subject: "newer", date: "2026-01-05T00:00:00+00:00",
                   files: { "a.c" => "v2\n", "configure.ac" => ac_init("20devel") })
    master_sha = repo.rev_parse("master")
    patch = generate_patch(fixture.path, old, "a.c", "patched\n", @patch_dir)
    message = message_with_patch(patch)
    message.update_column(:created_at, Time.zone.parse("2026-01-10T00:00:00+00:00"))

    outcome, = apply_one.call(message.id, master_sha: master_sha)

    expect(outcome).to eq(:applied_on_base)
    record = PatchBranch.find_by(message_id: message.id)
    expect(record.base_sha).to eq(old)
    expect(record.pg_major).to eq(19)
  end

  it "leaves pg_major nil when the base tree has no configure file" do
    base = fixture.commit(subject: "base", files: { "a.c" => "v1\n" })
    patch = generate_patch(fixture.path, base, "a.c", "v2\n", @patch_dir)
    message = message_with_patch(patch)

    apply_one.call(message.id, master_sha: base)

    expect(PatchBranch.find_by(message_id: message.id).pg_major).to be_nil
  end

  describe "#persist_error" do
    def message_that_blows_up(base)
      patch = generate_patch(fixture.path, base, "a.c", "v2\n", @patch_dir)
      message = message_with_patch(patch)
      allow_any_instance_of(PatchBranches::Applier).to receive(:apply).and_raise("boom")
      message
    end

    it "writes the error row for a normal call and reports no save problem" do
      base = fixture.commit(subject: "base", files: { "a.c" => "v1\n" })
      message = message_that_blows_up(base)
      one = apply_one

      error = capture_error { one.call(message.id, master_sha: base) }

      expect(one.persist_error(error)).to be_nil
      expect(one.save_error).to be_nil
      record = PatchBranch.find_by(message_id: message.id)
      expect(record).to have_attributes(status: "failed", failure_stage: "error")
      expect(record.failure_reason).to include("boom")
    end

    it "returns the save error when the row itself cannot be written" do
      base = fixture.commit(subject: "base", files: { "a.c" => "v1\n" })
      message = message_that_blows_up(base)
      one = apply_one
      error = capture_error { one.call(message.id, master_sha: base) }
      allow_any_instance_of(PatchBranch).to receive(:save!)
        .and_raise(ActiveRecord::RecordNotUnique, "duplicate branch_name")

      expect(one.persist_error(error)).to be_a(ActiveRecord::RecordNotUnique)
      expect(one.save_error).to be_a(ActiveRecord::RecordNotUnique)
    end

    it "forgets the previous message, so a later failure cannot rewrite its row" do
      base = fixture.commit(subject: "base", files: { "a.c" => "v1\n" })
      patch = generate_patch(fixture.path, base, "a.c", "v2\n", @patch_dir)
      message = message_with_patch(patch)
      one = apply_one
      expect(one.call(message.id, master_sha: base).first).to eq(:applied_on_master)
      before = PatchBranch.find_by(message_id: message.id).attributes

      error = capture_error { one.call(-1, master_sha: base) }

      expect(error).to be_a(ActiveRecord::RecordNotFound)
      expect(one.record).to be_nil
      expect(one.persist_error(error)).to be_nil
      expect(PatchBranch.find_by(message_id: message.id).attributes).to eq(before)
      expect(PatchBranch.count).to eq(1)
    end
  end

  describe "master_only" do
    let(:old_date) { "2026-01-01T00:00:00+00:00" }

    def applied_on_old_base
      @old = fixture.commit(subject: "old", date: old_date,
                            files: { "a.c" => "v1\n", "configure.ac" => ac_init("19devel") })
      patch = generate_patch(fixture.path, @old, "a.c", "patched\n", @patch_dir)
      message = message_with_patch(patch)
      message.update_column(:created_at, Time.zone.parse("2026-01-10T00:00:00+00:00"))
      expect(apply_one.call(message.id, master_sha: @old).first).to eq(:applied_on_master)
      message
    end

    it "moves the branch and the row onto the new master when the patch still applies" do
      message = applied_on_old_base
      new_master = fixture.commit(subject: "unrelated", files: { "b.c" => "other\n" },
                                  date: "2026-02-01T00:00:00+00:00")

      outcome, record = apply_one.call(message.id, master_sha: new_master, master_only: true)

      expect(outcome).to eq(:applied_on_master)
      record.reload
      expect(record.on_master).to eq(true)
      expect(record.base_sha).to eq(new_master)
      expect(record.master_apply_error).to be_nil
      expect(record.base_committed_at).to eq(Time.zone.parse("2026-02-01T00:00:00+00:00"))
      expect(record.base_commit_height).to eq(2)
      expect(record.pg_major).to eq(19)
      expect(repo.rev_parse("#{record.branch_name}~1")).to eq(new_master)
      expect(repo.rev_parse("rebase_probe_#{record.branch_name}")).to be_nil
    end

    it "touches only the master attempt columns when the patch no longer applies" do
      message = applied_on_old_base
      new_master = fixture.commit(subject: "conflicting", files: { "a.c" => "v2\n" },
                                  date: "2026-02-01T00:00:00+00:00")
      before = PatchBranch.find_by(message_id: message.id).attributes

      outcome, record = apply_one.call(message.id, master_sha: new_master, master_only: true)

      expect(outcome).to eq(:master_apply_failed)
      expect(record.reload.attributes.except(*volatile)).to eq(before.except(*volatile))
      expect(record.master_apply_error).to be_present
      expect(record.last_master_apply_at).to be_within(1.minute).of(Time.current)
    end

    it "keeps the row applied when the probe blows up mid-apply" do
      message = applied_on_old_base
      new_master = fixture.commit(subject: "unrelated", files: { "b.c" => "other\n" })
      before = PatchBranch.find_by(message_id: message.id).attributes
      one = apply_one
      allow_any_instance_of(PatchBranches::Applier).to receive(:apply)
        .and_raise(PatchBranches::GitRepo::Error, "worktree gone")

      error = capture_error { one.call(message.id, master_sha: new_master, master_only: true) }

      expect(one.persist_error(error)).to be_nil
      record = PatchBranch.find_by(message_id: message.id)
      expect(record.status).to eq("applied")
      expect(record.failure_stage).to be_nil
      expect(record.attributes.except(*volatile)).to eq(before.except(*volatile))
      expect(record.master_apply_error).to include("worktree gone")
    end

    it "keeps the row applied when extraction fails during a probe" do
      message = applied_on_old_base
      new_master = fixture.commit(subject: "unrelated", files: { "b.c" => "other\n" })
      before = PatchBranch.find_by(message_id: message.id).attributes
      allow_any_instance_of(PatchBranches::PatchsetExtractor).to receive(:extract)
        .and_raise(PatchBranches::PatchsetExtractor::Error, "no patch attachments")

      outcome, record = apply_one.call(message.id, master_sha: new_master, master_only: true)

      expect(outcome).to eq(:extract_failed)
      record.reload
      expect(record.status).to eq("applied")
      expect(record.failure_stage).to be_nil
      expect(record.attributes.except(*volatile)).to eq(before.except(*volatile))
      expect(record.master_apply_error).to include("no patch attachments")
    end

    it "leaves everything alone when the row already sits on this master" do
      message = applied_on_old_base
      branch = branch_of(message)
      before_sha = repo.rev_parse(branch)
      before = PatchBranch.find_by(message_id: message.id).attributes

      outcome, = apply_one.call(message.id, master_sha: @old, master_only: true)

      expect(outcome).to eq(:already_current)
      expect(repo.rev_parse(branch)).to eq(before_sha)
      expect(PatchBranch.find_by(message_id: message.id).attributes).to eq(before)
    end

    it "skips a message with no row to rebase instead of writing a first version" do
      base = fixture.commit(subject: "base", files: { "a.c" => "v1\n" })
      patch = generate_patch(fixture.path, base, "a.c", "v2\n", @patch_dir)
      message = message_with_patch(patch)

      outcome, record = apply_one.call(message.id, master_sha: base, master_only: true)

      expect(outcome).to eq(:skipped)
      expect(record).not_to be_persisted
      expect(PatchBranch.count).to eq(0)
    end

    it "leaves the existing branch alone when the probe fails" do
      message = applied_on_old_base
      branch = branch_of(message)
      before_sha = repo.rev_parse(branch)
      new_master = fixture.commit(subject: "conflicting", files: { "a.c" => "v2\n" })

      apply_one.call(message.id, master_sha: new_master, master_only: true)

      expect(repo.rev_parse(branch)).to eq(before_sha)
      expect(repo.rev_parse("rebase_probe_#{branch}")).to be_nil
    end

    it "probes an unchanged applied row that a normal call would skip" do
      message = applied_on_old_base
      new_master = fixture.commit(subject: "unrelated", files: { "b.c" => "other\n" })

      expect(apply_one.call(message.id, master_sha: new_master).first).to eq(:skipped)
      expect(apply_one.call(message.id, master_sha: new_master, master_only: true).first)
        .to eq(:applied_on_master)
    end
  end
end
