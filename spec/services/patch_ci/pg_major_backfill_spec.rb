require "rails_helper"

RSpec.describe PatchCi::PgMajorBackfill do
  let(:detector) { instance_double(PatchCi::EraDetector) }
  let(:io) { StringIO.new }

  def backfill
    described_class.new(detector: detector, io: io).call
  end

  it "takes the value from the latest run when there is one" do
    row = create(:patch_branch, base_sha: "a" * 40)
    run = create(:patch_ci_run, patch_branch: row, pg_major: 18)
    row.update_columns(latest_ci_run_id: run.id)
    expect(detector).not_to receive(:major_for)

    backfill

    expect(row.reload.pg_major).to eq(18)
  end

  it "prefers the run over the detector when both have an answer" do
    row = create(:patch_branch, base_sha: "a" * 40)
    run = create(:patch_ci_run, patch_branch: row, pg_major: 18)
    row.update_columns(latest_ci_run_id: run.id)
    allow(detector).to receive(:major_for).and_return(19)

    backfill

    expect(row.reload.pg_major).to eq(18)
  end

  it "falls back to the detector for rows with no run" do
    row = create(:patch_branch, base_sha: "b" * 40)
    allow(detector).to receive(:major_for).with("b" * 40).and_return(15)

    backfill

    expect(row.reload.pg_major).to eq(15)
  end

  it "leaves rows with no base sha alone" do
    row = create(:patch_branch, base_sha: nil, status: "failed", failure_stage: "apply")

    backfill

    expect(row.reload.pg_major).to be_nil
  end

  it "does not rewrite rows that already have a major" do
    row = create(:patch_branch, base_sha: "c" * 40, pg_major: 20)
    expect(detector).not_to receive(:major_for)

    backfill

    expect(row.reload.pg_major).to eq(20)
  end

  it "does not bump updated_at" do
    row = create(:patch_branch, base_sha: "d" * 40)
    row.update_columns(updated_at: 3.days.ago)
    before = row.reload.updated_at
    allow(detector).to receive(:major_for).and_return(19)

    backfill

    expect(row.reload.updated_at).to be_within(1.second).of(before)
  end

  it "names rows the detector could not answer and counts writes, not rows seen" do
    filled = create(:patch_branch, base_sha: "e" * 40)
    run = create(:patch_ci_run, patch_branch: filled, pg_major: 18)
    filled.update_columns(latest_ci_run_id: run.id)
    missed = create(:patch_branch, base_sha: "f" * 40)
    allow(detector).to receive(:major_for).with("f" * 40).and_return(nil)

    backfill

    expect(io.string).to include("filled 1 rows from runs")
    expect(io.string).to include("no major for #{missed.branch_name} base #{'f' * 40}")
    expect(io.string).to include("detector pass done, wrote 0/1")
    expect(missed.reload.pg_major).to be_nil
  end
end
