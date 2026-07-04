require "rails_helper"

RSpec.describe HackorumCommits::Config do
  it "parses options with defaults" do
    cfg = described_class.parse(%w[--server http://localhost:3000 --repo /tmp/pg])
    expect(cfg.server).to eq("http://localhost:3000")
    expect(cfg.repo).to eq("/tmp/pg")
    expect(cfg.state_dir).to eq(".hackorum-commits")
  end

  it "parses --since and --until date bounds" do
    cfg = described_class.parse(%w[--since 2014-01-01 --until 2015-01-01])
    expect(cfg.since).to eq("2014-01-01")
    expect(cfg.until_date).to eq("2015-01-01")
  end

  it "defaults the date bounds to nil" do
    cfg = described_class.parse([])
    expect(cfg.since).to be_nil
    expect(cfg.until_date).to be_nil
  end
end
