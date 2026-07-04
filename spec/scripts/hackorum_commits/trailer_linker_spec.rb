require "rails_helper"

RSpec.describe HackorumCommits::TrailerLinker do
  let(:store) { HackorumCommits::Store.new(":memory:") }
  let(:api) { instance_double(HackorumCommits::ApiClient) }
  subject(:linker) { described_class.new(store: store, api: api) }

  it "writes a trailer link for a resolvable message-id" do
    allow(api).to receive(:resolve_message_id).with("disc@x")
      .and_return({ "topic_id" => 100, "mailing_lists" => [ "pgsql-hackers" ] })
    linked = linker.link(sha: "abc", message_ids: [ "disc@x" ])
    expect(linked).to be(true)
    row = store.links_for("abc").first
    expect(row["topic_id"]).to eq(100)
    expect(row["method"]).to eq("trailer")
    expect(row["verdict"]).to eq("related")
  end

  it "returns false when nothing resolves" do
    allow(api).to receive(:resolve_message_id).and_return(nil)
    expect(linker.link(sha: "abc", message_ids: [ "x@y" ])).to be(false)
    expect(store.links_for("abc")).to be_empty
  end
end
