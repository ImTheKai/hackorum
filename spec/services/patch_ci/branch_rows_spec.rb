require "rails_helper"

RSpec.describe PatchCi::BranchRows do
  let(:repo_state) { create(:patch_ci_repo_state, master_committed_at: Time.current) }
  let(:rows) { described_class.new(repo_state: repo_state) }

  def with_run(**run_attrs)
    branch = create(:patch_branch, base_committed_at: 1.day.ago, base_commit_height: 10,
                    pushed_at: 1.hour.ago, ci_status: "success")
    run = create(:patch_ci_run, patch_branch: branch, **run_attrs)
    branch.update_columns(latest_ci_run_id: run.id)
    [ branch, run ]
  end

  it "decorates rows with the health bucket and the base tier" do
    with_run

    row = rows.load(PatchBranch.current).first

    expect(row.health_bucket).to eq("fresh")
    expect(row.base_tier).to eq("recent")
  end

  it "attaches the latest run summary" do
    _branch, run = with_run(tests_total: 229, build_seconds: 185)

    row = rows.load(PatchBranch.current).first

    expect(row.latest_run_summary.id).to eq(run.id)
    expect(row.latest_run_summary.tests_total).to eq(229)
  end

  it "leaves the summary nil for a row that never ran" do
    create(:patch_branch)

    row = rows.load(PatchBranch.current).first

    expect(row.latest_run_summary).to be_nil
  end

  it "does not query runs at all when no row has one" do
    create(:patch_branch)

    sql = captured_queries { rows.load(PatchBranch.current) }

    expect(sql.none? { |q| q.include?("patch_ci_runs") }).to be(true)
  end

  it "never selects the payload column" do
    with_run(payload: { secret: "x" * 100 })

    sql = captured_queries { rows.load(PatchBranch.current) }
    run_queries = sql.select { |q| q.include?("patch_ci_runs") && q.start_with?("SELECT") }

    expect(run_queries).to be_present
    expect(run_queries.none? { |q| q.include?("payload") }).to be(true)
    # a revert to SELECT * would drop the word "payload" and pass vacuously
    expect(run_queries.none? { |q| q.include?(%("patch_ci_runs".*)) }).to be(true)
  end

  # the select excludes payload, so reading it off a summary must fail rather
  # than fetch 256KB of json per row
  it "raises on the payload of an attached summary" do
    with_run(payload: { secret: "x" * 100 })

    row = rows.load(PatchBranch.current).first

    expect { row.latest_run_summary.payload }.to raise_error(ActiveModel::MissingAttributeError)
  end

  it "loads the topic, so rendering a page does not query topics per row" do
    3.times { with_run }

    loaded = rows.load(PatchBranch.current)
    sql = captured_queries { loaded.each { |row| row.topic.title } }

    expect(sql.none? { |q| q.include?(%(FROM "topics")) }).to be(true)
  end

  it "loads many rows with one branch query and one run query" do
    3.times { with_run }

    sql = captured_queries { rows.load(PatchBranch.current) }

    expect(sql.count { |q| q.include?("health_bucket") }).to eq(1)
    expect(sql.count { |q| q.include?("patch_ci_runs") && q.start_with?("SELECT") }).to eq(1)
  end
end
