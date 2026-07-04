require "rails_helper"

RSpec.describe HackorumCommits::OverlapMatcher do
  let(:store) { HackorumCommits::Store.new(":memory:") }
  let(:config) { HackorumCommits::Config.parse([ "match" ]) }

  def add_commit(sha, files:, committed_at: "2009-06-01T00:00:00Z", stage: "quickfixed")
    store.upsert_commit(sha: sha, subject: "subj #{sha}", body: "body", authored_at: committed_at,
                        committed_at: committed_at, author_name: "A", author_email: "a@x",
                        committer_name: "C", committer_email: "c@x",
                        branches: [], versions: [], files: files)
    store.set_stage(sha, stage)
  end

  def add_patchset(message_id, topic_id, paths, at: "2009-05-20T00:00:00Z", title: "t", sender: "S")
    store.upsert_patchset(message_id: message_id, external_message_id: "m#{message_id}@x",
                          topic_id: topic_id, submitted_at: at, title: title, sender: sender,
                          paths: paths)
  end

  def filler_corpus
    20.times { |i| add_patchset(100 + i, 100 + i, [ "src/common#{i % 5}.c" ]) }
  end

  def run_match
    HackorumCommits::OverlapMatcher.new(store: store, config: config).match!
  end

  it "accepts deterministically on exact non-noise file-set match with dominance" do
    filler_corpus
    add_commit("aaa", files: [ "src/x.c", "src/y.c" ])
    add_patchset(1, 50, [ "src/x.c", "src/y.c" ])
    run_match
    links = store.links_for("aaa")
    expect(links.size).to eq(1)
    expect(links.first["method"]).to eq("file_overlap")
    expect(links.first["topic_id"]).to eq(50)
    expect(store.commit("aaa")["stage"]).to eq("matched")
  end

  it "queues candidates instead of accepting when two topics tie at jac=1" do
    filler_corpus
    add_commit("bbb", files: [ "src/x.c", "src/y.c" ])
    add_patchset(1, 50, [ "src/x.c", "src/y.c" ])
    add_patchset(2, 51, [ "src/x.c", "src/y.c" ])
    run_match
    expect(store.links_for("bbb")).to be_empty
    expect(store.candidates_for("bbb").map { |c| c["topic_id"] }).to match_array([ 50, 51 ])
  end

  it "queues instead of accepting when the exact match lacks dominance over a partial runner-up" do
    filler_corpus
    add_commit("bba", files: [ "src/x.c", "src/y.c" ])
    add_patchset(1, 50, [ "src/x.c", "src/y.c" ])
    add_patchset(2, 51, [ "src/x.c", "src/y.c", "src/z.c" ])
    run_match
    expect(store.links_for("bba")).to be_empty
    expect(store.candidates_for("bba").map { |c| c["topic_id"] }).to eq([ 50, 51 ])
  end

  it "queues instead of accepting when the exact candidate is not the top scorer" do
    filler_corpus
    add_commit("bbc", files: [ "src/x.c", "src/y.c", "configure" ])
    add_patchset(1, 50, [ "src/x.c", "src/y.c" ])
    add_patchset(2, 51, [ "src/x.c", "src/y.c", "configure", "src/z.c" ])
    run_match
    expect(store.links_for("bbc")).to be_empty
    expect(store.candidates_for("bbc").map { |c| c["topic_id"] }).to eq([ 51, 50 ])
  end

  it "queues partial overlaps above the judge floor" do
    filler_corpus
    add_commit("ccc", files: [ "src/x.c", "src/y.c", "src/z.c" ])
    add_patchset(1, 50, [ "src/x.c", "src/y.c" ])
    run_match
    expect(store.links_for("ccc")).to be_empty
    expect(store.candidates_for("ccc").map { |c| c["topic_id"] }).to eq([ 50 ])
  end

  it "abstains cleanly when nothing overlaps" do
    filler_corpus
    add_commit("ddd", files: [ "src/nowhere.c" ])
    run_match
    expect(store.links_for("ddd")).to be_empty
    expect(store.candidates_for("ddd")).to be_empty
    expect(store.commit("ddd")["stage"]).to eq("matched")
  end

  it "does not accept on noise-only overlap" do
    filler_corpus
    add_commit("eee", files: [ "configure" ])
    add_patchset(1, 50, [ "configure" ])
    run_match
    expect(store.links_for("eee")).to be_empty
  end

  it "ignores patchsets outside the window" do
    filler_corpus
    add_commit("fff", files: [ "src/x.c" ], committed_at: "2009-06-01T00:00:00Z")
    add_patchset(1, 50, [ "src/x.c" ], at: "2009-01-01T00:00:00Z")
    run_match
    expect(store.links_for("fff")).to be_empty
    expect(store.candidates_for("fff")).to be_empty
  end

  it "skips commits that already have a related link" do
    filler_corpus
    add_commit("ggg", files: [ "src/x.c", "src/y.c" ])
    store.add_link(sha: "ggg", topic_id: 9, mailing_list: nil, method: "trailer",
                   confidence: 1.0, verdict: "related", evidence: "", external_message_id: nil)
    add_patchset(1, 50, [ "src/x.c", "src/y.c" ])
    run_match
    expect(store.links_for("ggg").map { |l| l["method"] }).to eq([ "trailer" ])
  end
end
