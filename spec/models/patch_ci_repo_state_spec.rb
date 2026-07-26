require "rails_helper"

RSpec.describe PatchCiRepoState do
  it "current is nil on an empty table" do
    expect(described_class.current).to be_nil
  end

  it "refresh! creates then updates a single row" do
    described_class.refresh!(master_sha: "a" * 40, master_committed_at: 1.hour.ago,
                             master_commit_height: 100)
    described_class.refresh!(master_sha: "b" * 40, master_committed_at: Time.current,
                             master_commit_height: 101)
    expect(described_class.count).to eq(1)
    expect(described_class.current.master_sha).to eq("b" * 40)
    expect(described_class.current.master_commit_height).to eq(101)
  end

  it "stale? when fetched_at is old" do
    state = described_class.refresh!(master_sha: "a" * 40, master_committed_at: Time.current,
                                     master_commit_height: 1)
    expect(state.stale?).to be(false)
    state.update!(fetched_at: 10.minutes.ago)
    expect(state.stale?).to be(true)
  end
end
