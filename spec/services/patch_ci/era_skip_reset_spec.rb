require "rails_helper"

RSpec.describe PatchCi::EraSkipReset do
  let(:topic) { create(:topic) }

  def row(reason:, ci_status: "ci_none")
    message = create(:message, topic: topic, is_patch_submission: true)
    create(:patch_branch, topic: topic, message: message, status: "applied",
                          ci_status: ci_status, ci_skip_reason: reason)
  end

  it "clears the skip for a major whose era image now exists" do
    record = row(reason: PatchCi::PushGuard.no_era_image_reason(16))

    expect(described_class.new.call).to eq(1)
    record.reload
    expect(record.ci_status).to be_nil
    expect(record.ci_skip_reason).to be_nil
  end

  # the loop hazard: clearing a row the guard will only reject again burns a
  # planner slot every cycle forever
  it "leaves a major with no era image skipped" do
    record = row(reason: PatchCi::PushGuard.no_era_image_reason(8))

    expect(described_class.new.call).to eq(0)
    expect(record.reload.ci_status).to eq("ci_none")
  end

  it "leaves skips that have nothing to do with era images" do
    record = row(reason: "patchset touches .github/")

    expect(described_class.new.call).to eq(0)
    expect(record.reload.ci_status).to eq("ci_none")
  end

  it "does not touch a row that is not skipped" do
    record = row(reason: nil, ci_status: "success")

    expect(described_class.new.call).to eq(0)
    expect(record.reload.ci_status).to eq("success")
  end

  it "is idempotent - a second run finds nothing left to clear" do
    row(reason: PatchCi::PushGuard.no_era_image_reason(16))

    expect(described_class.new.call).to eq(1)
    expect(described_class.new.call).to eq(0)
  end

  it "follows eras.yml rather than a list of its own" do
    allow(PatchCi::Eras).to receive(:families).and_return(
      [ PatchCi::Eras::Family.new(name: "bookworm", majors: [ 16 ], enabled: false) ])
    record = row(reason: PatchCi::PushGuard.no_era_image_reason(16))

    expect(described_class.new.call).to eq(0)
    expect(record.reload.ci_status).to eq("ci_none")
  end
end
