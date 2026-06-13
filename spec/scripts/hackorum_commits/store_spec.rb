require "rails_helper"

RSpec.describe HackorumCommits::Store do
  it "bootstraps all working tables" do
    store = described_class.new(":memory:")
    tables = store.db.execute("SELECT name FROM sqlite_master WHERE type='table'").map { |r| r["name"] }
    expect(tables).to include(
      "commits", "commit_relations", "commit_facts",
      "thread_candidates", "thread_links", "api_cache", "llm_cache"
    )
  end

  it "upserts and reads a commit row" do
    store = described_class.new(":memory:")
    store.upsert_commit(sha: "abc", subject: "hi", body: "b",
                        authored_at: "2020-01-01", committed_at: "2020-01-02",
                        author_name: "A", author_email: "a@x", committer_name: "C",
                        committer_email: "c@x", branches: ["master"], versions: ["devel"])
    row = store.commit("abc")
    expect(row["subject"]).to eq("hi")
    expect(JSON.parse(row["branches"])).to eq(["master"])
  end
end
