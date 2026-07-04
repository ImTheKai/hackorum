require "rails_helper"
require "tmpdir"

RSpec.describe HackorumCommits::Store do
  let(:store) { described_class.new(":memory:") }

  it "bootstraps all working tables" do
    tables = store.db.execute("SELECT name FROM sqlite_master WHERE type='table'").map { |r| r["name"] }
    expect(tables).to include(
      "commits", "commit_relations", "commit_facts", "thread_links", "api_cache"
    )
  end

  it "upserts and reads a commit row" do
    store.upsert_commit(sha: "abc", subject: "hi", body: "b",
                        authored_at: "2020-01-01", committed_at: "2020-01-02",
                        author_name: "A", author_email: "a@x", committer_name: "C",
                        committer_email: "c@x", branches: [ "master" ], versions: [ "devel" ])
    row = store.commit("abc")
    expect(row["subject"]).to eq("hi")
    expect(JSON.parse(row["branches"])).to eq([ "master" ])
  end

  it "adds the files column to legacy databases" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "state.db")
      legacy = SQLite3::Database.new(path)
      legacy.execute("CREATE TABLE commits (sha TEXT PRIMARY KEY, subject TEXT)")
      legacy.close

      store = described_class.new(path)
      cols = store.db.execute("PRAGMA table_info(commits)").map { |r| r["name"] }
      expect(cols).to include("files")
    end
  end

  it "stores and updates the changed-file list" do
    store.upsert_commit(sha: "abc", subject: "hi", body: "b",
                        authored_at: "2020-01-01", committed_at: "2020-01-02",
                        author_name: "A", author_email: "a@x", committer_name: "C",
                        committer_email: "c@x", branches: [], versions: [],
                        files: [ "src/a.c", "src/b.c" ])
    expect(JSON.parse(store.commit("abc")["files"])).to eq([ "src/a.c", "src/b.c" ])

    store.upsert_commit(sha: "abc", subject: "hi", body: "b",
                        authored_at: "2020-01-01", committed_at: "2020-01-02",
                        author_name: "A", author_email: "a@x", committer_name: "C",
                        committer_email: "c@x", branches: [], versions: [],
                        files: [ "one.c", "two.c" ])
    expect(JSON.parse(store.commit("abc")["files"])).to eq([ "one.c", "two.c" ])
  end

  it "bootstraps corpus tables" do
    tables = store.db.execute("SELECT name FROM sqlite_master WHERE type='table'").map { |r| r["name"] }
    expect(tables).to include("patchsets", "corpus_sync_state", "match_candidates", "judgments")
  end

  it "upserts patchsets and iterates them" do
    store.upsert_patchset(message_id: 5, external_message_id: "x@y", topic_id: 7,
                          submitted_at: "2009-06-01T00:00:00Z", title: "T", sender: "S",
                          paths: [ "src/a.c" ])
    store.upsert_patchset(message_id: 5, external_message_id: "x@y", topic_id: 7,
                          submitted_at: "2009-06-01T00:00:00Z", title: "T2", sender: "S",
                          paths: [ "src/a.c", "src/b.c" ])
    rows = []
    store.each_patchset { |r| rows << r }
    expect(rows.size).to eq(1)
    expect(rows.first["title"]).to eq("T2")
    expect(JSON.parse(rows.first["paths"])).to eq([ "src/a.c", "src/b.c" ])
    expect(store.count_patchsets).to eq(1)
  end

  it "round-trips the corpus cursor" do
    expect(store.corpus_cursor).to be_nil
    store.set_corpus_cursor("2009-01-01T00:00:00Z,42")
    expect(store.corpus_cursor).to eq("2009-01-01T00:00:00Z,42")
  end

  it "replaces and reads match candidates ordered by score" do
    store.replace_candidates("abc", [
      { topic_id: 1, score: 3.0, jaccard: 0.4, n_overlap: 2, n_nonnoise: 2,
        date_gap_days: 10, title: "low", sender: "S", matched_paths: [ "a" ],
        patch_path_count: 3, submitted_at: "2009-01-01" },
      { topic_id: 2, score: 9.0, jaccard: 1.0, n_overlap: 2, n_nonnoise: 2,
        date_gap_days: 3, title: "high", sender: "S", matched_paths: [ "a", "b" ],
        patch_path_count: 2, submitted_at: "2009-01-05" }
    ])
    expect(store.candidates_for("abc").map { |c| c["topic_id"] }).to eq([ 2, 1 ])
    store.replace_candidates("abc", [])
    expect(store.candidates_for("abc")).to be_empty
  end

  it "caches judgments and deletes links by method" do
    expect(store.judgment_for("abc", 7, "h1")).to be_nil
    store.save_judgment(sha: "abc", topic_id: 7, prompt_hash: "h1",
                        verdict: "related", confidence: 0.9, evidence: "e", model: "m")
    expect(store.judgment_for("abc", 7, "h1")["verdict"]).to eq("related")

    store.add_link(sha: "abc", topic_id: 7, mailing_list: nil, method: "file_overlap",
                   confidence: 0.95, verdict: "related", evidence: "x", external_message_id: nil)
    store.add_link(sha: "abc", topic_id: 8, mailing_list: nil, method: "trailer",
                   confidence: 1.0, verdict: "related", evidence: "y", external_message_id: nil)
    store.delete_links_by_method("abc", "file_overlap")
    expect(store.links_for("abc").map { |l| l["method"] }).to eq([ "trailer" ])
  end

  it "iterates and counts commits across multiple stages" do
    store.upsert_commit(sha: "s1", subject: "a", body: "", authored_at: "2009-01-01",
                        committed_at: "2009-01-01T00:00:00Z", author_name: "A", author_email: "a",
                        committer_name: "C", committer_email: "c", branches: [], versions: [])
    store.upsert_commit(sha: "s2", subject: "b", body: "", authored_at: "2009-01-02",
                        committed_at: "2009-01-02T00:00:00Z", author_name: "A", author_email: "a",
                        committer_name: "C", committer_email: "c", branches: [], versions: [])
    store.set_stage("s1", "quickfixed")
    store.set_stage("s2", "matched")
    seen = []
    store.each_commit_at_stages(%w[quickfixed matched]) { |c| seen << c["sha"] }
    expect(seen).to eq(%w[s1 s2])
    expect(store.count_at_stages(%w[quickfixed matched])).to eq(2)
  end

  it "finds the oldest commit without a related link" do
    store.upsert_commit(sha: "old", subject: "s", body: "", authored_at: "2009-01-01",
                        committed_at: "2009-01-01T00:00:00Z", author_name: "A", author_email: "a",
                        committer_name: "C", committer_email: "c", branches: [], versions: [])
    store.upsert_commit(sha: "new", subject: "s", body: "", authored_at: "2010-01-01",
                        committed_at: "2010-01-01T00:00:00Z", author_name: "A", author_email: "a",
                        committer_name: "C", committer_email: "c", branches: [], versions: [])
    store.add_link(sha: "old", topic_id: 1, mailing_list: nil, method: "trailer",
                   confidence: 1.0, verdict: "related", evidence: "", external_message_id: nil)
    expect(store.oldest_unlinked_committed_at).to eq("2010-01-01T00:00:00Z")

    store.add_link(sha: "new", topic_id: 2, mailing_list: nil, method: "file_overlap",
                   confidence: 0.5, verdict: "unrelated", evidence: "", external_message_id: nil)
    expect(store.oldest_unlinked_committed_at).to eq("2010-01-01T00:00:00Z")
  end
end
