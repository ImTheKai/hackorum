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
end
