require "rails_helper"

RSpec.describe PatchBranch do
  it "is valid with the factory defaults" do
    expect(build(:patch_branch)).to be_valid
  end

  it "rejects unknown statuses" do
    expect(build(:patch_branch, status: "bogus")).not_to be_valid
  end

  it "rejects unknown failure stages" do
    expect(build(:patch_branch, status: "failed", failure_stage: "bogus")).not_to be_valid
  end

  it "round-trips conflict_files as a string array" do
    pb = create(:patch_branch, status: "failed", failure_stage: "apply",
                conflict_files: [ "src/a.c", "src/b.c" ])
    expect(pb.reload.conflict_files).to eq([ "src/a.c", "src/b.c" ])
  end

  it "enforces one branch per message" do
    pb = create(:patch_branch)
    dup = build(:patch_branch, message: pb.message, topic: pb.topic)
    expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "allows a nil ci_status" do
    expect(build(:patch_branch, ci_status: nil)).to be_valid
  end

  it "rejects an unknown ci_status" do
    expect(build(:patch_branch, ci_status: "bogus")).not_to be_valid
  end

  it "accepts a ci_status from PatchCiRun::STATUSES" do
    expect(build(:patch_branch, ci_status: "queued")).to be_valid
  end

  it "pushed scope returns only rows with a pushed_at" do
    pushed = create(:patch_branch, pushed_at: Time.current)
    create(:patch_branch, pushed_at: nil)
    expect(PatchBranch.pushed).to contain_exactly(pushed)
  end

  it "awaiting_ci scope returns only pushed_awaiting_ci rows" do
    awaiting = create(:patch_branch, ci_status: "pushed_awaiting_ci")
    create(:patch_branch, ci_status: "success")
    expect(PatchBranch.awaiting_ci).to contain_exactly(awaiting)
  end

  it "does not require a latest_ci_run" do
    expect(build(:patch_branch, latest_ci_run: nil)).to be_valid
  end
end
