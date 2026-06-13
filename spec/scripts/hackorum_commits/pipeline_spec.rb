require "rails_helper"

RSpec.describe HackorumCommits::Pipeline do
  let(:store) { HackorumCommits::Store.new(":memory:") }
  let(:config) { HackorumCommits::Config.parse(%w[--llm-model qwen]) }
  let(:api) { instance_double(HackorumCommits::ApiClient) }
  let(:llm) { instance_double(HackorumCommits::LlmClient) }

  before do
    store.upsert_commit(sha: "abc", subject: "Fix vacuum throttling",
                        body: "Reviewed-by: Jane <jane@x>\nDiscussion: https://postgr.es/m/d@x",
                        authored_at: "2020-01-01T00:00:00Z", committed_at: "2020-01-02T00:00:00Z",
                        author_name: "Dan", author_email: "dan@x",
                        committer_name: "Andrew", committer_email: "a@x",
                        branches: ["master"], versions: ["devel"], stage: "walked")
    allow(api).to receive(:resolve_message_id).with("d@x")
      .and_return({ "topic_id" => 100, "mailing_lists" => ["pgsql-hackers"] })
    allow(api).to receive(:search_candidates).and_return([])
    allow(llm).to receive(:complete).and_return({ "links" => [], "facts" => [] })
  end

  it "advances stages and is idempotent on re-run" do
    pipeline = described_class.new(config: config, store: store, api: api, llm: llm)

    pipeline.parse
    expect(store.commit("abc")["stage"]).to eq("parsed")
    expect(store.facts_for("abc").any? { |f| f["kind"] == "reviewer" }).to be(true)

    facts_count = store.facts_for("abc").size
    pipeline.parse # idempotent: skips parsed commits
    expect(store.facts_for("abc").size).to eq(facts_count)

    pipeline.discover
    expect(store.commit("abc")["stage"]).to eq("discovered")
    expect(store.candidates_for("abc").any? { |c| c["topic_id"] == 100 }).to be(true)

    pipeline.confirm
    expect(store.commit("abc")["stage"]).to eq("confirmed")
    expect(store.links_for("abc").any? { |l| l["topic_id"] == 100 }).to be(true)
  end
end
