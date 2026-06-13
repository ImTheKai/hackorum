require "rails_helper"

RSpec.describe HackorumCommits::ApiClient, :webmock do
  let(:store) { HackorumCommits::Store.new(":memory:") }
  let(:config) { HackorumCommits::Config.parse(%w[--server http://hk.test]) }
  let(:client) { described_class.new(config: config, store: store) }

  it "fetches and parses candidate search, caching the second call" do
    stub = stub_request(:get, "http://hk.test/topics/search_candidates.json")
           .with(query: hash_including("q" => "vacuum"))
           .to_return(status: 200, body: { candidates: [{ topic_id: 7, title: "T" }] }.to_json,
                      headers: { "Content-Type" => "application/json" })

    first = client.search_candidates(q: "vacuum", from: "2020-01-01T00:00:00Z",
                                     to: "2020-02-01T00:00:00Z", mailing_lists: [],
                                     patches_only: false, limit: 8)
    second = client.search_candidates(q: "vacuum", from: "2020-01-01T00:00:00Z",
                                      to: "2020-02-01T00:00:00Z", mailing_lists: [],
                                      patches_only: false, limit: 8)

    expect(first.first["topic_id"]).to eq(7)
    expect(second.first["topic_id"]).to eq(7)
    expect(stub).to have_been_requested.times(1)
  end

  it "resolves a message-id, returning nil on 404" do
    stub_request(:get, %r{http://hk\.test/messages/by-id/.*\.json})
      .to_return(status: 200, body: { topic_id: 9, mailing_lists: ["pgsql-hackers"] }.to_json,
                 headers: { "Content-Type" => "application/json" })
    expect(client.resolve_message_id("abc@x")["topic_id"]).to eq(9)

    WebMock.reset!
    stub_request(:get, %r{.*}).to_return(status: 404, body: "{}")
    expect(client.resolve_message_id("missing@x")).to be_nil
  end
end
