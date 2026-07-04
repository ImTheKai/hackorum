require "rails_helper"

RSpec.describe HackorumCommits::ApiClient, :webmock do
  let(:store) { HackorumCommits::Store.new(":memory:") }
  let(:config) { HackorumCommits::Config.parse(%w[--server http://hk.test]) }
  let(:client) { described_class.new(config: config, store: store) }

  it "resolves a message-id, returning nil on 404" do
    stub_request(:get, %r{http://hk\.test/messages/by-id/.*\.json})
      .to_return(status: 200, body: { topic_id: 9, mailing_lists: [ "pgsql-hackers" ] }.to_json,
                 headers: { "Content-Type" => "application/json" })
    expect(client.resolve_message_id("abc@x")["topic_id"]).to eq(9)

    WebMock.reset!
    stub_request(:get, %r{.*}).to_return(status: 404, body: "{}")
    expect(client.resolve_message_id("missing@x")).to be_nil
  end
end
