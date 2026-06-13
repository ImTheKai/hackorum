require "rails_helper"

RSpec.describe HackorumCommits::Discovery do
  let(:store) { HackorumCommits::Store.new(":memory:") }
  let(:config) { HackorumCommits::Config.parse(%w[--candidate-limit 3]) }
  let(:api) { instance_double(HackorumCommits::ApiClient) }
  subject(:discovery) { described_class.new(config: config, store: store, api: api) }

  it "strips boilerplate and includes contributor names in search terms" do
    facts = [ { kind: "author", value: "Dan Dev <dan@x>" }, { kind: "reported_by", value: "Bob <bob@x>" } ]
    terms = discovery.search_terms(subject: "Fix vacuum throttling bug", facts: facts)
    expect(terms).to include("vacuum", "throttling")
    expect(terms).not_to include("Fix")
    expect(terms.join(" ")).to include("Dan Dev")
  end

  it "computes an asymmetric date window" do
    from, to = discovery.date_window("2020-06-01T00:00:00Z")
    expect(Time.parse(from)).to be < Time.parse("2020-06-01T00:00:00Z")
    expect(Time.parse(to)).to be > Time.parse("2020-06-01T00:00:00Z")
    expect((Time.parse("2020-06-01T00:00:00Z") - Time.parse(from)).to_i).to eq(365 * 86_400)
  end

  it "records trailer and search candidates, keeping trailers past the cap" do
    allow(api).to receive(:resolve_message_id).with("disc@x")
      .and_return({ "topic_id" => 100, "mailing_lists" => [ "pgsql-hackers" ] })
    allow(api).to receive(:search_candidates).and_return(
      (1..10).map { |i| { "topic_id" => i, "title" => "t#{i}" } }
    )

    commit = { "sha" => "abc", "subject" => "Fix vacuum", "committed_at" => "2020-06-01T00:00:00Z" }
    discovery.discover(commit, facts: [], message_ids: [ "disc@x" ])

    rows = store.candidates_for("abc")
    trailer = rows.select { |r| r["source"] == "trailer" }
    search = rows.select { |r| r["source"] == "search" }
    expect(trailer.map { |r| r["topic_id"] }).to include(100)
    expect(search.size).to be <= 3
  end

  it "trailer candidate wins over search when the same topic_id appears in both" do
    allow(api).to receive(:resolve_message_id).with("shared@x")
      .and_return({ "topic_id" => 5, "mailing_lists" => [ "pgsql-hackers" ] })
    allow(api).to receive(:search_candidates).and_return(
      [
        { "topic_id" => 5,  "score" => 0.3, "title" => "overlap" },
        { "topic_id" => 10, "score" => 0.5, "title" => "other1" },
        { "topic_id" => 11, "score" => 0.4, "title" => "other2" }
      ]
    )

    commit = { "sha" => "def", "subject" => "Fix index vacuum bug", "committed_at" => "2020-06-01T00:00:00Z" }
    discovery.discover(commit, facts: [], message_ids: [ "shared@x" ])

    rows = store.candidates_for("def")
    topic5 = rows.find { |r| r["topic_id"] == 5 }
    expect(topic5).not_to be_nil
    expect(topic5["source"]).to eq("trailer")
    expect(topic5["prefilter_score"]).to eq(1.0)

    search = rows.select { |r| r["source"] == "search" }
    expect(search.size).to be <= 3
    expect(search.map { |r| r["topic_id"] }).not_to include(5)
  end

  it "trailer pre-seed does not reduce the search candidate budget" do
    allow(api).to receive(:resolve_message_id).with("trailer@x")
      .and_return({ "topic_id" => 99, "mailing_lists" => [ "pgsql-hackers" ] })
    search_hits = (1..10).map { |i| { "topic_id" => i, "score" => 0.5, "title" => "hit#{i}" } }
    allow(api).to receive(:search_candidates).and_return(search_hits, [])

    commit = { "sha" => "ghi", "subject" => "Fix index vacuum scan", "committed_at" => "2020-06-01T00:00:00Z" }
    discovery.discover(commit, facts: [], message_ids: [ "trailer@x" ])

    rows = store.candidates_for("ghi")
    trailer = rows.select { |r| r["source"] == "trailer" }
    search  = rows.select { |r| r["source"] == "search" }
    expect(trailer.map { |r| r["topic_id"] }).to include(99)
    expect(search.size).to eq(3)
    expect(rows.size).to eq(4)
  end
end
