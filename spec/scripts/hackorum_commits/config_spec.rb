require "rails_helper"

RSpec.describe HackorumCommits::Config do
  it "parses options with defaults" do
    cfg = described_class.parse(%w[--server http://localhost:3000 --repo /tmp/pg
                                   --llm-url http://x/v1 --llm-model m])
    expect(cfg.server).to eq("http://localhost:3000")
    expect(cfg.repo).to eq("/tmp/pg")
    expect(cfg.llm_url).to eq("http://x/v1")
    expect(cfg.llm_model).to eq("m")
    expect(cfg.state_dir).to eq(".hackorum-commits")
    expect(cfg.candidate_limit).to eq(8)
  end
end
