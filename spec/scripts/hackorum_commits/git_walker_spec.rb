require "rails_helper"

RSpec.describe HackorumCommits::GitWalker do
  let(:repo) { Rails.root.join("postgres").to_s }
  let(:store) { HackorumCommits::Store.new(":memory:") }

  it "derives major versions from ref names" do
    walker = described_class.new(repo: repo, store: store)
    expect(walker.version_for_ref("REL_17_STABLE")).to eq("17")
    expect(walker.version_for_ref("REL9_6_STABLE")).to eq("9.6")
    expect(walker.version_for_ref("master")).to eq("devel")
  end

  it "lists master plus REL_* refs" do
    walker = described_class.new(repo: repo, store: store)
    expect(walker.refs).to include("master")
    expect(walker.refs.any? { |r| r.start_with?("REL_17") || r.start_with?("REL9") }).to be(true)
  end

  it "persists commits with branches and versions when walking a bounded slice" do
    walker = described_class.new(repo: repo, store: store, branches: ["master"], limit: 50)
    walker.walk!
    master_sha = `cd #{repo} && git rev-parse master`.strip
    row = store.commit(master_sha)
    expect(row).to be_present
    expect(JSON.parse(row["branches"])).to include("master")
    expect(JSON.parse(row["versions"])).to include("devel")
  end

  it "records cherry_picked_from relations for commits sharing subject+author across branches" do
    sha1 = "aaa0000000000000000000000000000000000001"
    sha2 = "bbb0000000000000000000000000000000000002"

    store.upsert_commit(
      sha: sha1, subject: "Fix buffer overflow in executor",
      body: "", authored_at: "2023-01-01T00:00:00Z", committed_at: "2023-01-01T00:00:00Z",
      author_name: "Tom Lane", author_email: "tgl@sss.pgh.pa.us",
      committer_name: "Tom Lane", committer_email: "tgl@sss.pgh.pa.us",
      branches: ["REL_15_STABLE"], versions: ["15"]
    )
    store.upsert_commit(
      sha: sha2, subject: "Fix buffer overflow in executor",
      body: "", authored_at: "2023-01-02T00:00:00Z", committed_at: "2023-01-02T00:00:00Z",
      author_name: "Tom Lane", author_email: "tgl@sss.pgh.pa.us",
      committer_name: "Tom Lane", committer_email: "tgl@sss.pgh.pa.us",
      branches: ["master"], versions: ["devel"]
    )

    walker = described_class.new(repo: repo, store: store)
    walker.detect_backport_twins([sha1, sha2])

    relations = store.relations_for(sha2)
    expect(relations).not_to be_empty
    expect(relations.first["kind"]).to eq("cherry_picked_from")
    expect(relations.first["method"]).to eq("heuristic")
    expect(relations.first["to_sha"]).to eq(sha1)
  end
end
