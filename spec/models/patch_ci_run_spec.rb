require "rails_helper"

RSpec.describe PatchCiRun do
  it "rejects a status outside the enum" do
    run = build(:patch_ci_run, status: "wat")
    expect(run).not_to be_valid
  end

  it "refuses a duplicate run id and attempt" do
    existing = create(:patch_ci_run)
    dup = build(:patch_ci_run, github_run_id: existing.github_run_id,
                               run_attempt: existing.run_attempt)
    expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "allows a second attempt of the same run" do
    existing = create(:patch_ci_run)
    second = build(:patch_ci_run, patch_branch: existing.patch_branch,
                                  github_run_id: existing.github_run_id,
                                  run_attempt: 2)
    expect(second.save).to be(true)
  end

  it "knows which statuses are terminal" do
    expect(build(:patch_ci_run, status: "running")).not_to be_terminal
    expect(build(:patch_ci_run, status: "tests_failed")).to be_terminal
  end

  it "cascades from a deleted message through the branch to its runs" do
    run = create(:patch_ci_run)
    branch = run.patch_branch
    # topics.last_message_id has no on_delete strategy, so it would block the
    # delete before our FKs are ever reached; that is a separate pre-existing
    # issue, not what this example is about
    branch.topic.update_columns(last_message_id: nil)

    expect { branch.message.destroy! }.to change(PatchCiRun, :count).by(-1)
  end

  it "cascades at the database level when callbacks are bypassed" do
    run = create(:patch_ci_run)
    branch = run.patch_branch
    branch.update!(latest_ci_run_id: run.id)
    branch.topic.update_columns(last_message_id: nil)

    # a re-import deletes in bulk, so no Rails callback ever fires
    Message.where(id: branch.message_id).delete_all

    expect(PatchBranch.where(id: branch.id)).to be_empty
    expect(PatchCiRun.where(id: run.id)).to be_empty
  end

  it "nullifies latest_ci_run_id on the branch when just that run is deleted" do
    run = create(:patch_ci_run)
    branch = run.patch_branch
    branch.update!(latest_ci_run_id: run.id)

    run.destroy!

    expect(branch.reload.latest_ci_run_id).to be_nil
  end
end
