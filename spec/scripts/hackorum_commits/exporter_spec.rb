require "rails_helper"

RSpec.describe HackorumCommits::Exporter do
  let(:store) { HackorumCommits::Store.new(":memory:") }
  let(:config) { HackorumCommits::Config.parse([]) }

  before do
    store.upsert_commit(sha: "abc", subject: "Fix vacuum", body: "b",
                        authored_at: "2020-01-01", committed_at: "2020-01-02",
                        author_name: "Dan", author_email: "dan@x",
                        committer_name: "Andrew", committer_email: "a@x",
                        branches: [ "master", "REL_17_STABLE" ], versions: [ "devel", "17" ])
    store.add_fact(sha: "abc", kind: "reviewer", value: "Jane", method: "trailer", confidence: 1.0, evidence: "Reviewed-by: Jane")
    store.add_link(sha: "abc", topic_id: 100, mailing_list: "pgsql-hackers", method: "trailer",
                   confidence: 1.0, verdict: "related", evidence: "trailer", external_message_id: "m@x")
    store.add_link(sha: "abc", topic_id: 200, mailing_list: "pgsql-bugs", method: "trailer",
                   confidence: 0.3, verdict: "unrelated", evidence: "no", external_message_id: nil)
  end

  it "writes one merged JSONL record per commit, excluding unrelated links" do
    out = StringIO.new
    described_class.new(store: store, config: config).export(out)
    lines = out.string.each_line.map { |l| JSON.parse(l) }
    expect(lines.size).to eq(1)
    rec = lines.first
    expect(rec["sha"]).to eq("abc")
    expect(rec["versions"]).to include("17")
    expect(rec["committer"]["name"]).to eq("Andrew")
    expect(rec["facts"].map { |f| f["kind"] }).to include("reviewer")
    expect(rec["thread_links"].map { |l| l["topic_id"] }).to eq([ 100 ])
    expect(rec["generator"]["tool_version"]).to eq(HackorumCommits::VERSION)
  end
end
