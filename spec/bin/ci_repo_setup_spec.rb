require "rails_helper"
require "open3"

RSpec.describe "bin/ci-repo-setup" do
  around do |example|
    Dir.mktmpdir("ci-repo-setup") do |dir|
      @tmp = dir
      example.run
    end
  end

  # upstream: what git.postgresql.org stands in for. fork: what
  # hackorum-dev/postgres stands in for - a clone of upstream carrying our
  # branches and result refs.
  def upstream
    @upstream ||= GitFixtureRepo.new(File.join(@tmp, "upstream")).tap do |repo|
      repo.commit(subject: "upstream first")
      repo.create_branch("REL_18_STABLE")
      repo.tag("REL_18_4")
    end
  end

  def fork_of(source)
    path = File.join(@tmp, "fork")
    sh("git", "clone", "--quiet", "--bare", source.path, path)
    sh("git", "-C", path, "update-ref", "refs/heads/t123_1", "refs/heads/master")
    sh("git", "-C", path, "update-ref", "refs/hackorum-ci/4242", "refs/heads/master")
    path
  end

  def run_setup(fork_path:, repo:)
    env = { "CI_REPO_DIR" => repo, "CI_UPSTREAM_URL" => upstream.path, "CI_FORK_URL" => fork_path }
    out, err, status = Open3.capture3(env, Rails.root.join("bin/ci-repo-setup").to_s)
    raise "setup failed (#{status.exitstatus}): #{err}#{out}" unless status.success?
    out
  end

  def refs(repo, pattern)
    sh("git", "-C", repo, "for-each-ref", "--format=%(refname)", pattern).split("\n")
  end

  def sh(*args)
    out, err, status = Open3.capture3(*args)
    raise "#{args.join(' ')} failed: #{err}#{out}" unless status.success?
    out
  end

  it "provisions the layout the orchestrator expects" do
    repo = File.join(@tmp, "repo")
    run_setup(fork_path: fork_of(upstream), repo: repo)

    expect(sh("git", "-C", repo, "config", "remote.postgres.fetch").strip)
      .to eq("+refs/heads/*:refs/remotes/postgres/*")
    expect(refs(repo, "refs/remotes/postgres")).to include("refs/remotes/postgres/master",
                                                           "refs/remotes/postgres/REL_18_STABLE")
    expect(refs(repo, "refs/tags")).to include("refs/tags/REL_18_4")
    expect(refs(repo, "refs/heads")).to include("refs/heads/master", "refs/heads/t123_1")
    expect(refs(repo, "refs/hackorum-ci")).to eq([ "refs/hackorum-ci/4242" ])
  end

  # the fork's master is a mirror of upstream and can lag; the local ref is
  # planning input, so it follows upstream, not the mirror
  it "points master at upstream, not at the fork's copy" do
    fork_path = fork_of(upstream)
    upstream.commit(subject: "upstream second")
    repo = File.join(@tmp, "repo")

    run_setup(fork_path: fork_path, repo: repo)

    expect(sh("git", "-C", repo, "rev-parse", "refs/heads/master").strip)
      .to eq(sh("git", "-C", repo, "rev-parse", "refs/remotes/postgres/master").strip)
  end

  it "is idempotent" do
    repo = File.join(@tmp, "repo")
    fork_path = fork_of(upstream)
    run_setup(fork_path: fork_path, repo: repo)
    before = sh("git", "-C", repo, "for-each-ref", "--format=%(refname) %(objectname)")

    run_setup(fork_path: fork_path, repo: repo)

    expect(sh("git", "-C", repo, "for-each-ref", "--format=%(refname) %(objectname)")).to eq(before)
    expect(sh("git", "-C", repo, "remote").split("\n")).to contain_exactly("origin", "postgres")
  end

  it "repairs a changed remote url" do
    repo = File.join(@tmp, "repo")
    fork_path = fork_of(upstream)
    run_setup(fork_path: fork_path, repo: repo)
    sh("git", "-C", repo, "remote", "set-url", "postgres", "https://example.invalid/x.git")

    run_setup(fork_path: fork_path, repo: repo)

    expect(sh("git", "-C", repo, "remote", "get-url", "postgres").strip).to eq(upstream.path)
  end

  it "succeeds against a fork with no result refs yet" do
    path = File.join(@tmp, "fork")
    sh("git", "clone", "--quiet", "--bare", upstream.path, path)
    sh("git", "-C", path, "update-ref", "refs/heads/t123_1", "refs/heads/master")
    repo = File.join(@tmp, "repo")

    run_setup(fork_path: path, repo: repo)

    expect(refs(repo, "refs/hackorum-ci")).to eq([])
  end

  it "fails rather than reporting success when the upstream fetch fails" do
    repo = File.join(@tmp, "repo")
    env = {
      "CI_REPO_DIR" => repo,
      "CI_UPSTREAM_URL" => File.join(@tmp, "no-such-upstream"),
      "CI_FORK_URL" => fork_of(upstream)
    }

    _out, _err, status = Open3.capture3(env, Rails.root.join("bin/ci-repo-setup").to_s)

    expect(status).not_to be_success
  end
end
