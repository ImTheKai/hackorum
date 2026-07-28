require "rails_helper"

RSpec.describe PatchCi::MasterCheck do
  # master has to be inside the warn window, otherwise every probe old enough
  # to be overdue is still newer than master's commit and reads current instead
  let(:repo_state) { create(:patch_ci_repo_state, master_committed_at: 2.hours.ago) }
  let(:check) { described_class.new(repo_state: repo_state) }

  def tier_of(row)
    described_class.new(repo_state: repo_state)
                   .with_tier(PatchBranch.where(id: row.id)).first.check_tier
  end

  def branch(last_master_apply_at)
    create(:patch_branch, last_master_apply_at: last_master_apply_at)
  end

  it "is never without a probe" do
    expect(tier_of(branch(nil))).to eq("never")
  end

  it "is current when the probe is newer than master's commit" do
    expect(tier_of(branch(1.hour.ago))).to eq("current")
  end

  it "is current when the probe lands exactly on master's commit time" do
    expect(tier_of(branch(repo_state.master_committed_at))).to eq("current")
  end

  it "is behind just inside the warn window" do
    row = branch(PatchCi::Config::MASTER_CHECK_WARN_HOURS.hours.ago + 1.minute)
    expect(tier_of(row)).to eq("behind")
  end

  it "is overdue just outside the warn window" do
    row = branch(PatchCi::Config::MASTER_CHECK_WARN_HOURS.hours.ago - 1.minute)
    expect(tier_of(row)).to eq("overdue")
  end

  # the false-alarm case: an ancient probe against a master that has not moved
  # since is still current, because re-probing could not change the answer
  it "is current for an old probe when master has not moved since" do
    frozen = create(:patch_ci_repo_state, master_committed_at: 10.days.ago)
    row = create(:patch_branch, last_master_apply_at: 9.days.ago)

    tier = described_class.new(repo_state: frozen)
                          .with_tier(PatchBranch.where(id: row.id)).first.check_tier

    expect(tier).to eq("current")
  end

  it "is never for everything when there is no repo state" do
    row = branch(1.hour.ago)
    tier = described_class.new(repo_state: nil)
                          .with_tier(PatchBranch.where(id: row.id)).first.check_tier
    expect(tier).to eq("never")
  end

  describe "#with_tier" do
    it "keeps the row's own columns" do
      row = branch(1.hour.ago)

      loaded = check.with_tier(PatchBranch.where(id: row.id)).first

      expect(loaded.id).to eq(row.id)
      expect(loaded.branch_name).to eq(row.branch_name)
    end
  end

  describe "#filter" do
    it "narrows to the requested tiers" do
      current = branch(1.hour.ago)
      branch(nil)

      expect(check.filter(PatchBranch.all, [ "current" ]).pluck(:id)).to eq([ current.id ])
    end

    it "accepts several tiers" do
      current = branch(1.hour.ago)
      never = branch(nil)
      branch(PatchCi::Config::MASTER_CHECK_WARN_HOURS.hours.ago - 1.minute)

      ids = check.filter(PatchBranch.all, [ "current", "never" ]).pluck(:id)

      expect(ids).to match_array([ current.id, never.id ])
    end

    it "selects the probe-less rows for never" do
      never = branch(nil)
      branch(1.hour.ago)

      expect(check.filter(PatchBranch.all, [ "never" ]).pluck(:id)).to eq([ never.id ])
    end

    it "ignores unknown tier names and returns everything" do
      row = branch(1.hour.ago)
      expect(check.filter(PatchBranch.all, [ "bogus" ]).pluck(:id)).to eq([ row.id ])
    end

    it "keeps the known tiers out of a mixed list" do
      current = branch(1.hour.ago)
      branch(nil)

      ids = check.filter(PatchBranch.all, [ "current", "bogus" ]).pluck(:id)

      expect(ids).to eq([ current.id ])
    end

    it "returns everything for an empty list" do
      rows = [ branch(1.hour.ago), branch(nil) ]
      expect(check.filter(PatchBranch.all, []).pluck(:id)).to match_array(rows.map(&:id))
    end

    it "matches nothing but never when there is no repo state" do
      row = branch(1.hour.ago)
      blind = described_class.new(repo_state: nil)

      expect(blind.filter(PatchBranch.all, [ "current" ]).pluck(:id)).to be_empty
      expect(blind.filter(PatchBranch.all, [ "never" ]).pluck(:id)).to eq([ row.id ])
    end
  end

  describe "#counts" do
    it "groups every tier in one query" do
      branch(1.hour.ago)
      branch(PatchCi::Config::MASTER_CHECK_WARN_HOURS.hours.ago - 1.minute)
      branch(nil)

      # no row is behind, and the tier still has to come back as a zero
      expect(check.counts(PatchBranch.all)).to eq(
        "current" => 1, "behind" => 0, "overdue" => 1, "never" => 1
      )
    end

    it "puts everything under never without a repo state" do
      branch(1.hour.ago)
      branch(nil)

      counts = described_class.new(repo_state: nil).counts(PatchBranch.all)
      expect(counts).to eq("current" => 0, "behind" => 0, "overdue" => 0, "never" => 2)
    end
  end
end
