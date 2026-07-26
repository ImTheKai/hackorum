require "rails_helper"

RSpec.describe PatchCi::StuckRunMarker do
  it "marks long-silent pushed branches as infra_error" do
    stuck = create(:patch_branch, ci_status: "pushed_awaiting_ci",
                   pushed_at: (PatchCi::Config::STUCK_RUN_HOURS + 1).hours.ago)
    fresh = create(:patch_branch, ci_status: "running", pushed_at: 1.hour.ago)

    described_class.new.call

    expect(stuck.reload.ci_status).to eq("infra_error")
    expect(stuck.ci_skip_reason).to include("no CI verdict")
    expect(fresh.reload.ci_status).to eq("running")
  end

  it "leaves branches not in a waiting status untouched" do
    done = create(:patch_branch, ci_status: "success",
                  pushed_at: (PatchCi::Config::STUCK_RUN_HOURS + 1).hours.ago)

    described_class.new.call

    expect(done.reload.ci_status).to eq("success")
  end

  it "marks queued and running branches too" do
    queued = create(:patch_branch, ci_status: "queued",
                    pushed_at: (PatchCi::Config::STUCK_RUN_HOURS + 1).hours.ago)
    running = create(:patch_branch, ci_status: "running",
                     pushed_at: (PatchCi::Config::STUCK_RUN_HOURS + 1).hours.ago)

    described_class.new.call

    expect(queued.reload.ci_status).to eq("infra_error")
    expect(running.reload.ci_status).to eq("infra_error")
  end
end
