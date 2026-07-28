require "rails_helper"
require "open3"
require "fileutils"

RSpec.describe "bin/orchestrator-entrypoint" do
  around do |example|
    Dir.mktmpdir("orchestrator-entrypoint") do |dir|
      @tmp = dir
      example.run
    end
  end

  def run(*args, env: {}, chdir: nil)
    opts = chdir ? { chdir: chdir } : {}
    Open3.capture3(env, Rails.root.join("bin/orchestrator-entrypoint").to_s, *args, opts)
  end

  def provisioned_repo
    repo = File.join(@tmp, "repo")
    fixture = GitFixtureRepo.new(File.join(@tmp, "src"))
    fixture.commit(subject: "first")
    env = { "CI_REPO_DIR" => repo, "CI_UPSTREAM_URL" => fixture.path, "CI_FORK_URL" => fixture.path }
    out, err, status = Open3.capture3(env, Rails.root.join("bin/ci-repo-setup").to_s)
    raise "setup failed: #{err}#{out}" unless status.success?
    repo
  end

  it "installs the deploy key with owner-only permissions" do
    source = File.join(@tmp, "key")
    File.write(source, "PRIVATE KEY")
    File.chmod(0o644, source)
    dest = File.join(@tmp, "ssh", "deploy_key")

    _out, err, status = run("echo", "ok", env: { "HACKORUM_DEPLOY_KEY_PATH" => source,
                                                "HACKORUM_DEPLOY_KEY_DEST" => dest })

    expect(status).to be_success, err
    expect(File.read(dest)).to eq("PRIVATE KEY")
    expect(format("%o", File.stat(dest).mode & 0o777)).to eq("600")
  end

  it "does not mind a missing key source" do
    _out, _err, status = run("echo", "ok", env: { "HACKORUM_DEPLOY_KEY_PATH" => File.join(@tmp, "absent") })

    expect(status).to be_success
  end

  it "refuses to start the daemon without a provisioned repo" do
    _out, err, status = run("bin/orchestrator",
                            env: { "CI_REPO_DIR" => File.join(@tmp, "empty"),
                                   "HACKORUM_DEPLOY_KEY_PATH" => File.join(@tmp, "absent") })

    expect(status).not_to be_success
    expect(err).to include("bin/ci-repo-setup")
  end

  it "accepts a provisioned repo, execing the daemon after checks pass" do
    repo = provisioned_repo
    workdir = File.join(@tmp, "work")
    FileUtils.mkdir_p(File.join(workdir, "bin"))
    stub = File.join(workdir, "bin", "orchestrator")
    File.write(stub, "#!/bin/bash\necho daemon-started\n")
    File.chmod(0o755, stub)

    out, err, status = run("bin/orchestrator",
                          env: { "CI_REPO_DIR" => repo,
                                 "HACKORUM_DEPLOY_KEY_PATH" => File.join(@tmp, "absent") },
                          chdir: workdir)

    expect(status).to be_success, err
    expect(out).to include("daemon-started")
  end

  it "refuses a repo with a dangling master ref" do
    repo = provisioned_repo
    dangling_sha = "deadbeef" * 5
    File.write(File.join(repo, "refs", "heads", "master"), "#{dangling_sha}\n")

    _out, err, status = run("bin/orchestrator",
                            env: { "CI_REPO_DIR" => repo,
                                   "HACKORUM_DEPLOY_KEY_PATH" => File.join(@tmp, "absent") })

    expect(status).not_to be_success
    expect(err).to include("refs/heads/master")
    expect(err).to include("bin/ci-repo-setup")
  end

  it "execs any other command without checking the repo" do
    out, _err, status = run("echo", "passthrough",
                            env: { "CI_REPO_DIR" => File.join(@tmp, "empty"),
                                   "HACKORUM_DEPLOY_KEY_PATH" => File.join(@tmp, "absent") })

    expect(status).to be_success
    expect(out).to include("passthrough")
  end
end
