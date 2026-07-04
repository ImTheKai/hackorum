require "rails_helper"

RSpec.describe HackorumCommits::CorpusSync do
  let(:store) { HackorumCommits::Store.new(":memory:") }
  let(:config) do
    HackorumCommits::Config.parse([ "corpus-sync", "--server", "http://hackorum.test",
                                    "--corpus-since", "2009-01-01" ])
  end
  let(:api) { HackorumCommits::ApiClient.new(config: config, store: store) }

  def stub_page(since:, items:, next_cursor:)
    stub_request(:get, "http://hackorum.test/patch_submissions.json")
      .with(query: { "per" => "500", "since" => since })
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: JSON.generate(patch_submissions: items, next_cursor: next_cursor))
  end

  it "pages until empty, upserts patchsets, persists cursor" do
    stub_page(since: "2009-01-01", next_cursor: "c1", items: [
      { id: 1, message_id: "a@x", topic_id: 10, topic_title: "T1", sender: "S1",
        date: "2009-02-01T00:00:00Z", paths: [ "src/a.c" ] }
    ])
    stub_page(since: "c1", next_cursor: "c2", items: [
      { id: 2, message_id: "b@x", topic_id: 11, topic_title: "T2", sender: "S2",
        date: "2009-03-01T00:00:00Z", paths: [ "src/b.c", "src/c.c" ] }
    ])
    stub_page(since: "c2", next_cursor: nil, items: [])

    described_class.new(store: store, api: api, config: config).sync!

    expect(store.count_patchsets).to eq(2)
    expect(store.corpus_cursor).to eq("c2")
    row = nil
    store.each_patchset { |r| row = r if r["message_id"] == 2 }
    expect(row["external_message_id"]).to eq("b@x")
    expect(row["topic_id"]).to eq(11)
    expect(row["submitted_at"]).to eq("2009-03-01T00:00:00Z")
    expect(JSON.parse(row["paths"])).to eq([ "src/b.c", "src/c.c" ])
    expect(store.db.execute("SELECT COUNT(*) AS n FROM api_cache").first["n"]).to eq(0)
  end

  it "prefers --corpus-since over the stored cursor" do
    store.set_corpus_cursor("c9")
    request = stub_page(since: "2009-01-01", next_cursor: nil, items: [])

    described_class.new(store: store, api: api, config: config).sync!
    expect(request).to have_been_requested
  end

  it "resumes from the stored cursor" do
    store.set_corpus_cursor("c1")
    cfg = HackorumCommits::Config.parse([ "corpus-sync", "--server", "http://hackorum.test" ])
    stub_page(since: "c1", next_cursor: "c2", items: [
      { id: 2, message_id: "b@x", topic_id: 11, topic_title: "T2", sender: "S2",
        date: "2009-03-01T00:00:00Z", paths: [ "src/b.c" ] }
    ])
    stub_page(since: "c2", next_cursor: nil, items: [])

    described_class.new(store: store, api: HackorumCommits::ApiClient.new(config: cfg, store: store),
                        config: cfg).sync!
    expect(store.count_patchsets).to eq(1)
  end

  it "derives the initial since from the oldest unlinked commit minus the match window" do
    store.upsert_commit(sha: "s1", subject: "a", body: "", authored_at: "2009-06-01",
                        committed_at: "2009-06-01T00:00:00Z", author_name: "A", author_email: "a",
                        committer_name: "C", committer_email: "c", branches: [], versions: [])
    cfg = HackorumCommits::Config.parse([ "corpus-sync", "--server", "http://hackorum.test" ])
    expected_since = (Time.parse("2009-06-01T00:00:00Z") - 60 * 86_400).utc.iso8601
    stub_page(since: expected_since, next_cursor: nil, items: [])

    described_class.new(store: store, api: HackorumCommits::ApiClient.new(config: cfg, store: store),
                        config: cfg).sync!
    expect(store.count_patchsets).to eq(0)
  end

  it "skips cleanly when there is nothing to derive a window from" do
    cfg = HackorumCommits::Config.parse([ "corpus-sync", "--server", "http://hackorum.test" ])
    expect {
      described_class.new(store: store, api: HackorumCommits::ApiClient.new(config: cfg, store: store),
                          config: cfg).sync!
    }.not_to raise_error
  end
end
