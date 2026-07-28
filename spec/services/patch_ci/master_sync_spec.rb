require "rails_helper"

RSpec.describe PatchCi::MasterSync do
  let(:master_sha) { "a" * 40 }

  def result(success, output = "")
    instance_double(PatchBranches::GitRepo::Result, success?: success, output: output)
  end

  def repo(fetch: result(true), push: result(true), sha: master_sha)
    instance_double(PatchBranches::GitRepo).tap do |double|
      allow(double).to receive(:run).with("fetch", "--quiet", "postgres", "master").and_return(fetch)
      allow(double).to receive(:run).with("push", "origin", "#{sha}:refs/heads/master").and_return(push)
      allow(double).to receive(:rev_parse).and_return(sha)
    end
  end

  it "fetches upstream master and resolves the master ref" do
    git = repo
    allow(git).to receive(:rev_parse).with("postgres/master").and_return(master_sha)

    outcome = described_class.new(git).call

    expect(git).to have_received(:run).with("fetch", "--quiet", "postgres", "master")
    expect(outcome.sha).to eq(master_sha)
    expect(outcome.fetch_failed).to be(false)
  end

  # a ref left pointing at a remote nobody fetches resolves to nothing, falls
  # back to the local master and freezes the planner on an ancient sha
  it "derives the master ref from the upstream remote" do
    git = repo
    allow(git).to receive(:run).with("fetch", "--quiet", "upstream", "master").and_return(result(true))
    allow(git).to receive(:rev_parse).with("upstream/master").and_return(master_sha)

    outcome = described_class.new(git, upstream_remote: "upstream").call

    expect(git).to have_received(:rev_parse).with("upstream/master")
    expect(outcome.sha).to eq(master_sha)
  end

  it "lets an explicit master ref win over the derived one" do
    git = repo
    allow(git).to receive(:run).with("fetch", "--quiet", "upstream", "master").and_return(result(true))
    allow(git).to receive(:rev_parse).with("refs/heads/pinned").and_return(master_sha)

    outcome = described_class.new(git, upstream_remote: "upstream",
                                       master_ref: "refs/heads/pinned").call

    expect(git).to have_received(:rev_parse).with("refs/heads/pinned")
    expect(outcome.sha).to eq(master_sha)
  end

  it "falls back to the local master when the remote ref is unknown" do
    git = repo
    allow(git).to receive(:rev_parse).with("postgres/master").and_return(nil)
    allow(git).to receive(:rev_parse).with("master").and_return(master_sha)

    expect(described_class.new(git).call.sha).to eq(master_sha)
  end

  it "raises when no master ref resolves at all" do
    git = repo(sha: nil)

    expect { described_class.new(git).call }.to raise_error(described_class::Error, /cannot resolve postgres\/master/)
  end

  it "reports a failed fetch and carries on" do
    git = repo(fetch: result(false, "no route to host"))

    outcome = nil
    expect { outcome = described_class.new(git).call }.to output(/master fetch failed: no route to host/).to_stderr

    expect(outcome.fetch_failed).to be(true)
    expect(outcome.sha).to eq(master_sha)
  end

  it "mirrors the resolved sha to the push remote" do
    git = repo

    expect(described_class.new(git).call.mirror_error).to be_nil
    expect(git).to have_received(:run).with("push", "origin", "#{master_sha}:refs/heads/master")
  end

  it "reports a failed mirror push without raising" do
    git = repo(push: result(false, "remote: Write access denied"))

    outcome = nil
    expect { outcome = described_class.new(git).call }.to output(/Write access denied/).to_stderr

    expect(outcome.mirror_error).to include("Write access denied")
  end

  # an empty message would be a truthy blank: callers would see a failure with
  # nothing to report and the warn would trail off after the colon
  it "reports a push that failed silently as no output" do
    git = repo(push: result(false, ""))

    outcome = nil
    expect { outcome = described_class.new(git).call }.to output(/mirror push failed: no output/).to_stderr

    expect(outcome.mirror_error).to eq("no output")
  end

  it "warns only once while the mirror error stays the same" do
    git = repo(push: result(false, "remote: Write access denied"))
    syncer = described_class.new(git)

    expect { syncer.call }.to output(/mirror push failed/).to_stderr
    expect { syncer.call }.not_to output.to_stderr
  end

  it "warns again when the mirror error changes" do
    git = repo(push: result(false, "first"))
    syncer = described_class.new(git)
    expect { syncer.call }.to output(/first/).to_stderr

    allow(git).to receive(:run).with("push", "origin", "#{master_sha}:refs/heads/master")
                               .and_return(result(false, "second"))

    expect { syncer.call }.to output(/second/).to_stderr
  end

  # the throttle has to reset on success, or a mirror that recovers and then
  # breaks the same way again stays silent for the life of the process
  it "warns again when the same error returns after a success" do
    git = repo(push: result(false, "remote: Write access denied"))
    syncer = described_class.new(git)
    expect { syncer.call }.to output(/mirror push failed/).to_stderr

    allow(git).to receive(:run).with("push", "origin", "#{master_sha}:refs/heads/master")
                               .and_return(result(true))
    expect { syncer.call }.not_to output.to_stderr

    allow(git).to receive(:run).with("push", "origin", "#{master_sha}:refs/heads/master")
                               .and_return(result(false, "remote: Write access denied"))

    expect { syncer.call }.to output(/mirror push failed/).to_stderr
  end

  it "skips the push when mirroring is off" do
    git = repo

    expect(described_class.new(git, mirror: false).call.mirror_error).to be_nil
    expect(git).not_to have_received(:run).with("push", "origin", anything)
  end
end
