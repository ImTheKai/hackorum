require "rails_helper"

RSpec.describe HackorumCommits::Pipeline do
  let(:store) { HackorumCommits::Store.new(":memory:") }
  let(:pipeline) do
    HackorumCommits::Pipeline.new(
      config: HackorumCommits::Config.parse([]), store: store,
      api: instance_double(HackorumCommits::ApiClient)
    )
  end

  def linked_commit(sha, subject: "Fix typo", body: "oops")
    store.upsert_commit(sha: sha, subject: subject, body: body,
      authored_at: nil, committed_at: "2026-06-02T00:00:00Z", author_name: nil, author_email: nil,
      committer_name: "C", committer_email: "c@x", branches: [], versions: [])
    store.set_stage(sha, "linked")
  end

  def trailer_link(sha, topic_id)
    store.add_link(sha: sha, topic_id: topic_id, mailing_list: "pgsql-hackers",
      method: "trailer", confidence: 1.0, verdict: "related",
      evidence: "Discussion trailer", external_message_id: "m#{topic_id}@x")
  end

  it "uses the explicit fixes_commit reference path with quickfix_ref" do
    linked_commit("orig")
    trailer_link("orig", 9)
    linked_commit("qf")
    store.add_fact(sha: "qf", kind: "fixes_commit", value: "orig",
      method: "commit_ref", confidence: 0.95, evidence: "orig")

    pipeline.quickfix

    qf_link = store.links_for("qf").find { |l| l["method"] == "quickfix_ref" }
    expect(qf_link["topic_id"]).to eq(9)
    expect(qf_link["confidence"]).to eq(0.95)
    expect(qf_link["verdict"]).to eq("quickfix")
    rel = store.relations_for("qf").find { |r| r["kind"] == "quickfix_of" }
    expect(rel["to_sha"]).to eq("orig")
    expect(store.commit("qf")["stage"]).to eq("quickfixed")
  end

  it "resolves an abbreviated fixes_commit reference by unique prefix" do
    linked_commit("abcdef0123456789")
    trailer_link("abcdef0123456789", 7)
    linked_commit("qf")
    store.add_fact(sha: "qf", kind: "fixes_commit", value: "abcdef01",
      method: "commit_ref", confidence: 0.95, evidence: "abcdef01")

    pipeline.quickfix

    qf_link = store.links_for("qf").find { |l| l["method"] == "quickfix_ref" }
    expect(qf_link["topic_id"]).to eq(7)
  end

  it "creates no link when the fix target has no patch links" do
    linked_commit("plain")
    linked_commit("qf")
    store.add_fact(sha: "qf", kind: "fixes_commit", value: "plain",
      method: "commit_ref", confidence: 0.95, evidence: "plain")

    pipeline.quickfix

    expect(store.links_for("qf")).to be_empty
    expect(store.relations_for("qf")).to be_empty
    expect(store.commit("qf")["stage"]).to eq("quickfixed")
  end

  it "creates no link when the fix target is not in the store" do
    linked_commit("qf")
    store.add_fact(sha: "qf", kind: "fixes_commit", value: "not_in_store",
      method: "commit_ref", confidence: 0.95, evidence: "not_in_store")

    pipeline.quickfix

    expect(store.links_for("qf")).to be_empty
    expect(store.relations_for("qf")).to be_empty
    expect(store.commit("qf")["stage"]).to eq("quickfixed")
  end

  it "does not add a quickfix link to a commit already linked as the patch" do
    linked_commit("orig")
    trailer_link("orig", 9)
    # This commit is itself linked to its own discussion AND names a fix
    # target - it must be skipped, not turned into a quickfix.
    linked_commit("self")
    trailer_link("self", 5)
    store.add_fact(sha: "self", kind: "fixes_commit", value: "orig",
      method: "commit_ref", confidence: 0.95, evidence: "orig")

    pipeline.quickfix

    expect(store.links_for("self").map { |l| l["method"] }).to contain_exactly("trailer")
    expect(store.relations_for("self")).to be_empty
    expect(store.commit("self")["stage"]).to eq("quickfixed")
  end
end
