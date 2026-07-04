require "rails_helper"

RSpec.describe HackorumCommits::LlmClient do
  let(:config) do
    HackorumCommits::Config.parse([ "judge", "--llm-url", "http://llm.test/v1", "--llm-model", "m1" ])
  end
  let(:client) { described_class.new(config: config) }
  let(:schema) { { name: "j", schema: { type: "object" } } }

  it "returns the parsed structured content" do
    stub_request(:post, "http://llm.test/v1/chat/completions")
      .with(body: hash_including("model" => "m1", "temperature" => 0))
      .to_return(status: 200, body: JSON.generate(
        choices: [ { message: { content: '{"verdict":"related","confidence":0.9,"evidence":"e"}' } } ]
      ))
    result = client.complete(system: "sys", user: "usr", schema: schema)
    expect(result["verdict"]).to eq("related")
  end

  it "raises on non-200" do
    stub_request(:post, "http://llm.test/v1/chat/completions").to_return(status: 500, body: "boom")
    expect { client.complete(system: "s", user: "u", schema: schema) }
      .to raise_error(HackorumCommits::LlmClient::Error)
  end

  it "raises on missing content" do
    stub_request(:post, "http://llm.test/v1/chat/completions")
      .to_return(status: 200, body: JSON.generate(choices: []))
    expect { client.complete(system: "s", user: "u", schema: schema) }
      .to raise_error(HackorumCommits::LlmClient::Error, /missing content/)
  end

  it "raises on unparseable content" do
    stub_request(:post, "http://llm.test/v1/chat/completions")
      .to_return(status: 200, body: JSON.generate(choices: [ { message: { content: "not json" } } ]))
    expect { client.complete(system: "s", user: "u", schema: schema) }
      .to raise_error(HackorumCommits::LlmClient::Error)
  end

  it "raises on transport errors" do
    stub_request(:post, "http://llm.test/v1/chat/completions").to_timeout
    expect { client.complete(system: "s", user: "u", schema: schema) }
      .to raise_error(HackorumCommits::LlmClient::Error)
  end
end
