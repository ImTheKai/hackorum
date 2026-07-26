require "rails_helper"

RSpec.describe PatchBranches::Applier do
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

  def worktree
    repo.run!("worktree", "add", "--detach", @wt_dir, "master")
    PatchBranches::GitRepo.new(@wt_dir)
  end

  it "applies an mbox patch and creates the branch" do
    base = fixture.commit(subject: "base", files: { "a.c" => "v1\n" })
    patch = generate_patch(fixture.path, base, "a.c", "v2\n", @patch_dir)

    result = described_class.new(worktree).apply(base, [ patch ], "t1_1")

    expect(result).to be_success
    branch_sha = repo.rev_parse("t1_1")
    expect(branch_sha).not_to be_nil
    expect(repo.run!("show", "#{branch_sha}:a.c").stdout).to eq("v2\n")
  end

  it "applies a bare diff with a synthetic commit" do
    base = fixture.commit(subject: "base", files: { "a.c" => "v1\n" })
    after = fixture.commit(subject: "after", files: { "a.c" => "v2\n" })
    diff = generate_diff(fixture.path, base, after, @patch_dir)

    result = described_class.new(worktree).apply(base, [ diff ], "t2_1")

    expect(result).to be_success
    branch_sha = repo.rev_parse("t2_1")
    expect(repo.run!("show", "#{branch_sha}:a.c").stdout).to eq("v2\n")
  end

  it "reports conflicts with the offending files" do
    old = fixture.commit(subject: "old", files: { "a.c" => "v1\n" })
    head = fixture.commit(subject: "head", files: { "a.c" => "conflicting\n" })
    patch = generate_patch(fixture.path, old, "a.c", "patched\n", @patch_dir)

    wt = worktree
    result = described_class.new(wt).apply(head, [ patch ], "t3_1")

    expect(result).not_to be_success
    expect(result.conflict_files).to include("a.c")
    expect(result.failed_patch).to eq(File.basename(patch))
    expect(repo.rev_parse("t3_1")).to be_nil
    expect(wt.run!("status", "--porcelain").stdout).to eq("")
  end

  it "reports conflicts for a bare diff with a 3-way merge" do
    old = fixture.commit(subject: "old", files: { "a.c" => "v1\n" })
    after = fixture.commit(subject: "after", files: { "a.c" => "patched\n" })
    head = fixture.commit(subject: "head", files: { "a.c" => "conflicting\n" })
    diff = generate_diff(fixture.path, old, after, @patch_dir)

    result = described_class.new(worktree).apply(head, [ diff ], "t4_1")

    expect(result).not_to be_success
    expect(result.conflict_files).to include("a.c")
  end

  it "reuses a worktree for a good apply after a failed one" do
    old = fixture.commit(subject: "old", files: { "a.c" => "v1\n" })
    head = fixture.commit(subject: "head", files: { "a.c" => "conflicting\n" })
    bad_patch = generate_patch(fixture.path, old, "a.c", "patched\n", @patch_dir)

    applier = described_class.new(worktree)
    bad_result = applier.apply(head, [ bad_patch ], "t5_bad")
    expect(bad_result).not_to be_success

    base = fixture.commit(subject: "base2", files: { "b.c" => "v1\n" })
    good_patch = generate_patch(fixture.path, base, "b.c", "v2\n", @patch_dir)
    good_result = applier.apply(base, [ good_patch ], "t5_good")

    expect(good_result).to be_success
    expect(repo.rev_parse("t5_good")).not_to be_nil
  end

  it "drops a cover letter with no diff content in a series" do
    base = fixture.commit(subject: "base", files: { "a.c" => "v1\n" })
    good_patch = generate_patch(fixture.path, base, "a.c", "v2\n", @patch_dir)

    cover = File.join(@patch_dir, "0000-cover-letter.patch")
    File.write(cover, <<~MBOX)
      From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001
      From: t <t@example.com>
      Date: Sat, 25 Jul 2026 00:00:00 +0000
      Subject: [PATCH 0/1] *** SUBJECT HERE ***

      *** BLURB HERE ***

      t (1):
        change

    MBOX

    result = described_class.new(worktree).apply(base, [ cover, good_patch ], "t6_1")

    expect(result).to be_success
    branch_sha = repo.rev_parse("t6_1")
    expect(repo.run!("show", "#{branch_sha}:a.c").stdout).to eq("v2\n")
  end

  it "skips a degenerate bare diff and applies the good one in a series" do
    base = fixture.commit(subject: "base", files: { "a.c" => "v1\n" })
    after = fixture.commit(subject: "after", files: { "a.c" => "v2\n" })
    diff = generate_diff(fixture.path, base, after, @patch_dir)

    junk = File.join(@patch_dir, "0000-junk.diff")
    File.write(junk, "this is not a diff\n")

    result = described_class.new(worktree).apply(base, [ junk, diff ], "t7_1")

    expect(result).to be_success
    branch_sha = repo.rev_parse("t7_1")
    expect(repo.run!("show", "#{branch_sha}:a.c").stdout).to eq("v2\n")
  end

  it "retries with --directory when the patch was generated from a subdirectory" do
    base = fixture.commit(subject: "base",
                          files: { "src/backend/foo.c" => "line1\nline2\nline3\nline4\n" })

    sub = GitFixtureRepo.new(File.join(File.dirname(@repo_dir), "subrepo"))
    sub_base = sub.commit(subject: "base", files: { "backend/foo.c" => "line1\nline2\nline3\n" })
    patch = generate_patch(sub.path, sub_base, "backend/foo.c",
                           "line1\nCHANGED\nline3\n", @patch_dir)

    result = described_class.new(worktree).apply(base, [ patch ], "t9_1")

    expect(result).to be_success
    expect(result.output).to include("--directory=src/")
    branch_sha = repo.rev_parse("t9_1")
    expect(repo.run!("show", "#{branch_sha}:src/backend/foo.c").stdout)
      .to eq("line1\nCHANGED\nline3\nline4\n")
  end

  it "keeps the original failure when no prefix qualifies" do
    base = fixture.commit(subject: "base", files: { "src/backend/foo.c" => "v1\n" })

    sub = GitFixtureRepo.new(File.join(File.dirname(@repo_dir), "subrepo"))
    sub_old = sub.commit(subject: "old", files: { "elsewhere/foo.c" => "e1\ne2\ne3\n" })
    sub_new = sub.commit(subject: "new", files: { "elsewhere/foo.c" => "e1\nX\ne3\n" })
    diff = generate_diff(sub.path, sub_old, sub_new, @patch_dir)

    wt = worktree
    result = described_class.new(wt).apply(base, [ diff ], "t10_1")

    expect(result).not_to be_success
    expect(result.output).to include("elsewhere/foo.c: does not exist in index")
    expect(repo.rev_parse("t10_1")).to be_nil
    expect(wt.run!("status", "--porcelain").stdout).to eq("")
  end

  it "fails a series that produces no commits instead of recording a phantom branch" do
    base = fixture.commit(subject: "base", files: { "a.c" => "v1\n" })

    junk = File.join(@patch_dir, "0000-junk.diff")
    File.write(junk, "this is not a diff\n")

    result = described_class.new(worktree).apply(base, [ junk ], "t8_1")

    expect(result).not_to be_success
    expect(result.output).to match(/no commits/)
    expect(repo.rev_parse("t8_1")).to be_nil
  end

  it "treats a context diff as a failure, not an empty skip" do
    base = fixture.commit(subject: "base", files: { "a.c" => "line one\nline two\n" })

    ctx = File.join(@patch_dir, "fix.diff")
    File.write(ctx, <<~PATCH)
      *** a/a.c
      --- b/a.c
      ***************
      *** 1,2 ****
      ! line one
        line two
      --- 1,2 ----
      ! line 1
        line two
    PATCH

    result = described_class.new(worktree).apply(base, [ ctx ], "t9_1")

    expect(result).not_to be_success
    expect(result.output).to match(/unsupported patch format/)
    expect(repo.rev_parse("t9_1")).to be_nil
  end

  it "backdates commits to committed_at and reproduces the same sha" do
    base = fixture.commit(subject: "base", files: { "a.c" => "v1\n" })
    after = fixture.commit(subject: "after", files: { "a.c" => "v3\n" })
    patch = generate_patch(fixture.path, base, "a.c", "v2\n", @patch_dir)
    diff = generate_diff(fixture.path, base, after, @patch_dir)
    submitted = Time.utc(2021, 3, 4, 5, 6, 7)

    wt = worktree
    applier = described_class.new(wt)

    expect(applier.apply(base, [ patch ], "t11_1", committed_at: submitted)).to be_success
    committer = repo.run!("log", "-1", "--format=%cI", "t11_1").stdout.strip
    expect(Time.parse(committer)).to eq(submitted)

    first_sha = repo.rev_parse("t11_1")
    expect(applier.apply(base, [ patch ], "t11_1", committed_at: submitted)).to be_success
    expect(repo.rev_parse("t11_1")).to eq(first_sha)

    expect(applier.apply(base, [ diff ], "t11_2", committed_at: submitted)).to be_success
    author, committer = repo.run!("log", "-1", "--format=%aI %cI", "t11_2").stdout.strip.split
    expect(Time.parse(author)).to eq(submitted)
    expect(Time.parse(committer)).to eq(submitted)
  end

  it "removes the stale branch when a re-apply fails" do
    old = fixture.commit(subject: "old", files: { "a.c" => "v1\n" })
    head = fixture.commit(subject: "head", files: { "a.c" => "conflicting\n" })
    good = generate_patch(fixture.path, old, "a.c", "v2\n", @patch_dir)

    wt = worktree
    applier = described_class.new(wt)
    expect(applier.apply(old, [ good ], "t10_1")).to be_success
    expect(repo.rev_parse("t10_1")).not_to be_nil

    result = applier.apply(head, [ good ], "t10_1")

    expect(result).not_to be_success
    expect(repo.rev_parse("t10_1")).to be_nil
  end
end
