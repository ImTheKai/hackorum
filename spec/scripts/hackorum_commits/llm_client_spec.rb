require "rails_helper"

RSpec.describe HackorumCommits::LlmClient, :webmock do
  let(:store) { HackorumCommits::Store.new(":memory:") }
  let(:config) { HackorumCommits::Config.parse(%w[--llm-url http://llm.test/v1 --llm-model qwen]) }
  let(:client) { described_class.new(config: config, store: store) }
  let(:schema) { { name: "verdicts", schema: { type: "object", properties: { ok: { type: "boolean" } } } } }

  it "posts a chat completion with json_schema and parses the content, caching" do
    payload = { choices: [{ message: { content: { ok: true }.to_json } }] }
    stub = stub_request(:post, "http://llm.test/v1/chat/completions")
           .to_return(status: 200, body: payload.to_json,
                      headers: { "Content-Type" => "application/json" })

    a = client.complete(system: "sys", user: "u", schema: schema)
    b = client.complete(system: "sys", user: "u", schema: schema)

    expect(a).to eq({ "ok" => true })
    expect(b).to eq({ "ok" => true })
    expect(stub).to have_been_requested.times(1)
  end

  it "sends model and response_format in the request body" do
    stub_request(:post, "http://llm.test/v1/chat/completions")
      .with { |req|
        body = JSON.parse(req.body)
        body["model"] == "qwen" &&
          body["response_format"]["type"] == "json_schema" &&
          body["messages"].first["role"] == "system"
      }
      .to_return(status: 200, body: { choices: [{ message: { content: "{}" } }] }.to_json)

    expect(client.complete(system: "s", user: "u", schema: schema)).to eq({})
  end
end
