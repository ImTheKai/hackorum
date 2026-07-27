require "rails_helper"

RSpec.describe PatchCi::BaseFreshness do
  let(:repo_state) { create(:patch_ci_repo_state, master_committed_at: Time.current) }
  let(:freshness) { described_class.new(repo_state: repo_state) }

  def tier_of(row)
    described_class.new(repo_state: repo_state)
                   .with_tier(PatchBranch.where(id: row.id)).first.base_tier
  end

  def branch_based(days_ago)
    create(:patch_branch, base_committed_at: days_ago && repo_state.master_committed_at - days_ago.days)
  end

  it "is recent just inside the rebase window" do
    expect(tier_of(branch_based(PatchCi::Config::REBASE_AFTER_DAYS - 1))).to eq("recent")
  end

  it "is stale at the rebase window" do
    expect(tier_of(branch_based(PatchCi::Config::REBASE_AFTER_DAYS + 1))).to eq("stale")
  end

  it "is stale just inside a year" do
    expect(tier_of(branch_based(364))).to eq("stale")
  end

  it "is stale at the year mark" do
    expect(tier_of(branch_based(PatchCi::Config::ANCIENT_AFTER_DAYS))).to eq("stale")
  end

  it "is ancient one day past the year mark" do
    expect(tier_of(branch_based(PatchCi::Config::ANCIENT_AFTER_DAYS + 1))).to eq("ancient")
  end

  it "is ancient past a year" do
    expect(tier_of(branch_based(400))).to eq("ancient")
  end

  it "is unknown without base metadata" do
    expect(tier_of(branch_based(nil))).to eq("unknown")
  end

  it "is unknown for everything when there is no repo state" do
    row = branch_based(1)
    tier = described_class.new(repo_state: nil)
                          .with_tier(PatchBranch.where(id: row.id)).first.base_tier
    expect(tier).to eq("unknown")
  end

  describe "#with_tier" do
    it "keeps the row's own columns" do
      row = branch_based(1)

      loaded = freshness.with_tier(PatchBranch.where(id: row.id)).first

      expect(loaded.id).to eq(row.id)
      expect(loaded.branch_name).to eq(row.branch_name)
    end
  end

  describe "#filter" do
    it "narrows to the requested tiers" do
      recent = branch_based(1)
      branch_based(400)

      ids = freshness.filter(PatchBranch.all, [ "recent" ]).pluck(:id)

      expect(ids).to eq([ recent.id ])
    end

    it "accepts several tiers" do
      recent = branch_based(1)
      stale = branch_based(100)
      branch_based(400)

      ids = freshness.filter(PatchBranch.all, [ "recent", "stale" ]).pluck(:id)

      expect(ids).to match_array([ recent.id, stale.id ])
    end

    it "selects the base-less rows for unknown" do
      unknown = branch_based(nil)
      branch_based(1)

      expect(freshness.filter(PatchBranch.all, [ "unknown" ]).pluck(:id)).to eq([ unknown.id ])
    end

    it "ignores unknown tier names and returns everything" do
      row = branch_based(1)
      expect(freshness.filter(PatchBranch.all, [ "bogus" ]).pluck(:id)).to eq([ row.id ])
    end

    it "keeps the known tiers out of a mixed list" do
      recent = branch_based(1)
      branch_based(400)

      ids = freshness.filter(PatchBranch.all, [ "recent", "bogus" ]).pluck(:id)

      expect(ids).to eq([ recent.id ])
    end

    it "returns everything for an empty list" do
      rows = [ branch_based(1), branch_based(400) ]
      expect(freshness.filter(PatchBranch.all, []).pluck(:id)).to match_array(rows.map(&:id))
    end

    # no repo state = every row is unknown, so every other facet is empty
    it "matches nothing but unknown when there is no repo state" do
      row = branch_based(1)
      blind = described_class.new(repo_state: nil)

      expect(blind.filter(PatchBranch.all, [ "recent" ]).pluck(:id)).to be_empty
      expect(blind.filter(PatchBranch.all, [ "unknown" ]).pluck(:id)).to eq([ row.id ])
    end
  end

  describe "#counts" do
    it "groups every tier in one query" do
      branch_based(1)
      branch_based(400)
      branch_based(nil)

      counts = freshness.counts(PatchBranch.all)
      expect(counts).to eq("recent" => 1, "stale" => 0, "ancient" => 1, "unknown" => 1)
    end

    it "puts everything under unknown without a repo state" do
      branch_based(1)
      branch_based(nil)

      counts = described_class.new(repo_state: nil).counts(PatchBranch.all)
      expect(counts).to eq("recent" => 0, "stale" => 0, "ancient" => 0, "unknown" => 2)
    end
  end
end
