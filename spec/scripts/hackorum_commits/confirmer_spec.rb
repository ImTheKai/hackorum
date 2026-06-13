require "rails_helper"

RSpec.describe HackorumCommits::Confirmer do
  let(:store) { HackorumCommits::Store.new(":memory:") }
  let(:llm) { instance_double(HackorumCommits::LlmClient) }
  subject(:confirmer) { described_class.new(store: store, llm: llm) }

  let(:commit) { { "sha" => "abc", "subject" => "Fix vacuum", "body" => "details" } }
  let(:candidates) do
    [
      { "topic_id" => 100, "source" => "trailer", "metadata" => { "mailing_lists" => [ "pgsql-hackers" ] }.to_json },
      { "topic_id" => 200, "source" => "search", "metadata" => { "title" => "vacuum perf", "mailing_lists" => [ "pgsql-bugs" ] }.to_json }
    ]
  end

  it "always links trailer candidates and applies LLM verdicts to search candidates" do
    allow(llm).to receive(:complete).and_return(
      "links" => [
        { "topic_id" => 200, "verdict" => "related", "confidence" => 0.8, "evidence" => "same crash" }
      ],
      "facts" => [ { "kind" => "cve", "value" => "CVE-2025-9999" } ]
    )

    confirmer.confirm(commit, candidates: candidates)

    links = store.links_for("abc").index_by { |l| l["topic_id"] }
    expect(links[100]["method"]).to eq("trailer")
    expect(links[100]["confidence"]).to eq(1.0)
    expect(links[200]["method"]).to eq("llm")
    expect(links[200]["verdict"]).to eq("related")
    expect(links[200]["mailing_list"]).to eq("pgsql-bugs")

    facts = store.facts_for("abc")
    expect(facts.any? { |f| f["kind"] == "cve" && f["method"] == "llm" }).to be(true)
  end
end
