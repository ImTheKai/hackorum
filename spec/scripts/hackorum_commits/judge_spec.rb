require "rails_helper"

RSpec.describe HackorumCommits::Judge do
  let(:store) { HackorumCommits::Store.new(":memory:") }
  let(:config) do
    HackorumCommits::Config.parse([ "judge", "--llm-url", "http://llm.test/v1", "--llm-model", "m1" ])
  end
  let(:judge) { described_class.new(store: store, config: config) }

  def add_commit(sha, stage: "matched")
    store.upsert_commit(sha: sha, subject: "Fix psql tab completion", body: "Patch from Jane Doe.",
                        authored_at: "2009-06-01", committed_at: "2009-06-01T00:00:00Z",
                        author_name: "A", author_email: "a@x", committer_name: "C",
                        committer_email: "c@x", branches: [], versions: [], files: [ "src/x.c" ])
    store.set_stage(sha, stage)
  end

  def cand(topic_id, score:, sender: "Jane Doe")
    { topic_id: topic_id, score: score, jaccard: 0.5, n_overlap: 1, n_nonnoise: 1,
      date_gap_days: 5, title: "psql tab completion fix", sender: sender,
      matched_paths: [ "src/x.c" ], patch_path_count: 2, submitted_at: "2009-05-27T00:00:00Z" }
  end

  def stub_llm(verdict:, confidence:)
    stub_request(:post, "http://llm.test/v1/chat/completions")
      .to_return(status: 200, body: JSON.generate(choices: [ { message: {
        content: JSON.generate(verdict: verdict, confidence: confidence, evidence: "ev")
      } } ]))
  end

  it "links on a confident related verdict and caches the judgment" do
    add_commit("aaa")
    store.replace_candidates("aaa", [ cand(50, score: 9.0) ])
    stub = stub_llm(verdict: "related", confidence: 0.92)

    judge.judge!
    links = store.links_for("aaa")
    expect(links.size).to eq(1)
    expect(links.first["method"]).to eq("file_overlap_judge")
    expect(links.first["confidence"]).to be_within(0.001).of(0.92)
    expect(store.commit("aaa")["stage"]).to eq("judged")

    store.set_stage("aaa", "matched")
    store.delete_links_by_method("aaa", "file_overlap_judge")
    judge.judge!
    expect(stub).to have_been_requested.once
    expect(store.links_for("aaa").size).to eq(1)
  end

  it "does not link below the confidence floor but records the judgment" do
    add_commit("bbb")
    store.replace_candidates("bbb", [ cand(50, score: 9.0) ])
    stub_llm(verdict: "related", confidence: 0.5)
    judge.judge!
    expect(store.links_for("bbb")).to be_empty
    expect(store.commit("bbb")["stage"]).to eq("judged")
    row = store.db.execute("SELECT COUNT(*) AS n FROM judgments WHERE sha = 'bbb'").first
    expect(row["n"]).to eq(1)
  end

  it "stops at the first accepted candidate" do
    add_commit("ccc")
    store.replace_candidates("ccc", [ cand(50, score: 9.0), cand(51, score: 4.0) ])
    stub = stub_llm(verdict: "related", confidence: 0.95)
    judge.judge!
    expect(store.links_for("ccc").map { |l| l["topic_id"] }).to eq([ 50 ])
    expect(stub).to have_been_requested.once
  end

  it "treats schema-invalid responses as unrelated without caching them" do
    add_commit("ddd")
    store.replace_candidates("ddd", [ cand(50, score: 9.0) ])
    stub_request(:post, "http://llm.test/v1/chat/completions")
      .to_return(status: 200, body: JSON.generate(choices: [ { message: {
        content: JSON.generate(nonsense: true)
      } } ]))
    judge.judge!
    expect(store.links_for("ddd")).to be_empty
    expect(store.commit("ddd")["stage"]).to eq("judged")
    row = store.db.execute("SELECT COUNT(*) AS n FROM judgments WHERE sha = 'ddd'").first
    expect(row["n"]).to eq(0)
  end

  it "links a later candidate after rejecting an earlier one, recording both judgments" do
    add_commit("ggg")
    store.replace_candidates("ggg", [ cand(50, score: 9.0), cand(51, score: 4.0) ])
    stub_request(:post, "http://llm.test/v1/chat/completions")
      .to_return(status: 200, body: JSON.generate(choices: [ { message: {
        content: JSON.generate(verdict: "unrelated", confidence: 0.7, evidence: "no")
      } } ]))
      .then
      .to_return(status: 200, body: JSON.generate(choices: [ { message: {
        content: JSON.generate(verdict: "related", confidence: 0.9, evidence: "yes")
      } } ]))
    judge.judge!
    expect(store.links_for("ggg").map { |l| l["topic_id"] }).to eq([ 51 ])
    row = store.db.execute("SELECT COUNT(*) AS n FROM judgments WHERE sha = 'ggg'").first
    expect(row["n"]).to eq(2)
  end

  it "aborts after consecutive schema-invalid responses, persisting nothing" do
    add_commit("hhh")
    store.replace_candidates("hhh", [ cand(50, score: 9.0), cand(51, score: 8.0), cand(52, score: 7.0) ])
    stub_request(:post, "http://llm.test/v1/chat/completions")
      .to_return(status: 200, body: JSON.generate(choices: [ { message: {
        content: JSON.generate(nonsense: true)
      } } ]))
    expect { judge.judge! }.to raise_error(HackorumCommits::LlmClient::Error, /consecutive schema-invalid/)
    expect(store.commit("hhh")["stage"]).to eq("matched")
    row = store.db.execute("SELECT COUNT(*) AS n FROM judgments WHERE sha = 'hhh'").first
    expect(row["n"]).to eq(0)
  end

  it "aborts the stage on transport errors, leaving commits at matched" do
    add_commit("eee")
    store.replace_candidates("eee", [ cand(50, score: 9.0) ])
    stub_request(:post, "http://llm.test/v1/chat/completions").to_return(status: 500, body: "down")
    expect { judge.judge! }.to raise_error(HackorumCommits::LlmClient::Error)
    expect(store.commit("eee")["stage"]).to eq("matched")
  end

  it "skips commits that already have a related link without calling the LLM" do
    add_commit("fff")
    store.replace_candidates("fff", [ cand(50, score: 9.0) ])
    store.add_link(sha: "fff", topic_id: 9, mailing_list: nil, method: "trailer",
                   confidence: 1.0, verdict: "related", evidence: "", external_message_id: nil)
    judge.judge!
    expect(store.commit("fff")["stage"]).to eq("judged")
    expect(store.links_for("fff").map { |l| l["method"] }).to eq([ "trailer" ])
  end

  it "judges only the listed sha prefixes and leaves other commits untouched" do
    add_commit("aaaaaaaaaa")
    add_commit("bbbbbbbbbb")
    store.replace_candidates("aaaaaaaaaa", [ cand(50, score: 9.0) ])
    store.replace_candidates("bbbbbbbbbb", [ cand(60, score: 9.0) ])
    cfg = HackorumCommits::Config.parse([ "judge", "--llm-url", "http://llm.test/v1",
                                          "--llm-model", "m1", "--only-shas", "aaaaaaaaaa" ])
    stub = stub_llm(verdict: "related", confidence: 0.9)
    described_class.new(store: store, config: cfg).judge!
    expect(store.links_for("aaaaaaaaaa").map { |l| l["method"] }).to eq([ "file_overlap_judge" ])
    expect(store.links_for("bbbbbbbbbb")).to be_empty
    expect(stub).to have_been_requested.once
    expect(store.commit("aaaaaaaaaa")["stage"]).to eq("matched")
  end

  it "puts evidence before verdict in the response schema (reason-before-decide)" do
    props = HackorumCommits::Judge::SCHEMA[:schema][:properties].keys
    expect(props.first).to eq(:evidence)
    expect(props).to include(:verdict, :confidence)
  end

  it "instructs the judge on report-credited and mechanical commits" do
    sp = HackorumCommits::Judge::SYSTEM_PROMPT.downcase
    expect(sp).to include("report")
    expect(sp).to match(/clean up|mechanical|cleanup/)
    expect(HackorumCommits::Judge::PROMPT_VERSION).to eq("v2")
  end
end
