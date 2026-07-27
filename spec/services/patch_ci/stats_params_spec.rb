require "rails_helper"

RSpec.describe PatchCi::StatsParams do
  def params(**attrs)
    described_class.new(params: ActionController::Parameters.new(attrs))
  end

  describe "range" do
    it "defaults to 7d when absent" do
      expect(params.range).to eq("7d")
    end

    it "rejects an unknown value" do
      expect(params(range: "'; drop table patch_ci_runs; --").range).to eq("7d")
    end

    it "accepts every documented value" do
      %w[24h 7d 30d 90d all].each do |value|
        expect(params(range: value).range).to eq(value)
      end
    end

    it "returns a bounded window for 24h" do
      freeze_time do
        expect(params(range: "24h").since).to eq(24.hours.ago)
      end
    end

    it "returns no window for all" do
      expect(params(range: "all").since).to be_nil
    end
  end

  describe "gran" do
    it "derives hour from 24h" do
      expect(params(range: "24h").gran).to eq("hour")
    end

    it "derives day from 7d and 30d" do
      expect(params(range: "7d").gran).to eq("day")
      expect(params(range: "30d").gran).to eq("day")
    end

    it "derives week from 90d and all" do
      expect(params(range: "90d").gran).to eq("week")
      expect(params(range: "all").gran).to eq("week")
    end

    it "lets an explicit value win over the derived one" do
      expect(params(range: "24h", gran: "week").gran).to eq("week")
    end

    it "falls back to the derived value when explicit input is junk" do
      expect(params(range: "24h", gran: "century").gran).to eq("hour")
    end
  end

  describe "active" do
    it "defaults to all" do
      expect(params.active).to eq("all")
      expect(params).not_to be_active_only
    end

    it "accepts active" do
      expect(params(active: "active")).to be_active_only
    end

    it "rejects anything else" do
      expect(params(active: "sometimes").active).to eq("all")
    end
  end

  describe "active_params" do
    it "carries the three resolved params and nothing else" do
      expect(params(range: "30d", active: "active", page: "4").active_params)
        .to eq(range: "30d", gran: "day", active: "active")
    end
  end

  describe "signature" do
    it "differs when any param differs" do
      base = params(range: "7d").signature
      expect(params(range: "30d").signature).not_to eq(base)
      expect(params(range: "7d", gran: "hour").signature).not_to eq(base)
      expect(params(range: "7d", active: "active").signature).not_to eq(base)
    end

    it "does not let a hyphen inside a value alias a different triple" do
      # a naive "-".join would flatten both of these to "7-d-ay-all"
      stub_const("PatchCi::StatsParams::RANGES", PatchCi::StatsParams::RANGES.merge("7-d" => 7.days, "7" => 7.days))
      stub_const("PatchCi::StatsParams::GRANS", PatchCi::StatsParams::GRANS + %w[ay d-ay])

      a = params(range: "7-d", gran: "ay", active: "all")
      b = params(range: "7", gran: "d-ay", active: "all")
      expect(a.signature).not_to eq(b.signature)
    end
  end
end
