require "rails_helper"

RSpec.describe PatchCi::TopicHistory do
  let(:repo_state) { create(:patch_ci_repo_state, master_committed_at: Time.current) }
  let(:topic) { create(:topic, last_message_at: Time.current) }

  def patchset(index, created_at:, **attrs)
    message = create(:message, topic: topic, created_at: created_at, is_patch_submission: true)
    create(:patch_branch, topic: topic, message: message,
           branch_name: "t#{topic.id}_#{index}", **attrs)
  end

  def history
    described_class.new(topic: topic, repo_state: repo_state)
  end

  it "orders patchsets newest first, superseded ones included" do
    old = patchset(1, created_at: 3.days.ago)
    fresh = patchset(2, created_at: 1.hour.ago)
    old.update!(superseded_by: fresh)

    expect(history.patchsets.map(&:id)).to eq([ fresh.id, old.id ])
  end

  it "decorates every row with the health bucket and the base tier" do
    patchset(1, created_at: 1.hour.ago, pushed_at: 1.hour.ago, ci_status: "success",
             base_committed_at: 1.day.ago, base_commit_height: 10,
             base_sha: repo_state.master_sha)

    row = history.patchsets.first

    expect(row.health_bucket).to eq("applies")
    expect(row.base_tier).to eq("recent")
  end

  it "groups runs under their branch, newest run first" do
    row = patchset(1, created_at: 1.hour.ago)
    first = create(:patch_ci_run, patch_branch: row, github_run_id: 100)
    second = create(:patch_ci_run, patch_branch: row, github_run_id: 200)

    expect(history.runs_for(row).map(&:id)).to eq([ second.id, first.id ])
  end

  it "has no runs for a patchset that never ran" do
    row = patchset(1, created_at: 1.hour.ago)

    expect(history.runs_for(row)).to eq([])
  end

  it "attaches the promoted run as the row summary" do
    row = patchset(1, created_at: 1.hour.ago)
    run = create(:patch_ci_run, patch_branch: row, tests_total: 229)
    row.update_columns(latest_ci_run_id: run.id)

    expect(history.patchsets.first.latest_run_summary.tests_total).to eq(229)
  end

  it "leaves the summary nil for a row with no promoted run" do
    patchset(1, created_at: 1.hour.ago)

    expect(history.patchsets.first.latest_run_summary).to be_nil
  end

  it "names the current patchset" do
    old = patchset(1, created_at: 3.days.ago)
    fresh = patchset(2, created_at: 1.hour.ago)
    old.update!(superseded_by: fresh)

    expect(history.current.id).to eq(fresh.id)
  end

  # the tag is per topic, so the run still holding it can belong to a patchset
  # that has since been superseded
  it "gives the live image to the newest run holding one, across patchsets" do
    old = patchset(1, created_at: 3.days.ago)
    fresh = patchset(2, created_at: 1.hour.ago)
    old.update!(superseded_by: fresh)
    holder = create(:patch_ci_run, patch_branch: old, github_run_id: 300,
                    image_ref: "ghcr.io/hackorum-dev/postgres-patch:t1")
    create(:patch_ci_run, patch_branch: fresh, github_run_id: 400, image_ref: nil)

    expect(history.live_image_run_id).to eq(holder.id)
  end

  it "has no live image when nothing ever built one" do
    row = patchset(1, created_at: 1.hour.ago)
    create(:patch_ci_run, patch_branch: row)

    expect(history.live_image_run_id).to be_nil
  end

  # a re-run carries a higher attempt against an older run id, so run-id
  # order would hand the tag to whichever run merely started later
  it "gives the live image to the run that finished last, not the one that started last" do
    row = patchset(1, created_at: 1.hour.ago)
    rerun = create(:patch_ci_run, patch_branch: row, github_run_id: 300, run_attempt: 2,
                   completed_at: 5.minutes.ago,
                   image_ref: "ghcr.io/hackorum-dev/postgres-patch:t1")
    create(:patch_ci_run, patch_branch: row, github_run_id: 400, completed_at: 2.hours.ago,
           image_ref: "ghcr.io/hackorum-dev/postgres-patch:t1")

    expect(history.live_image_run_id).to eq(rerun.id)
  end

  # record_unstorable writes an infra_error run with no timestamps at all;
  # read as "in flight" it would outrank every real run forever. Its insert
  # time is the only thing left to date it by, so it is set explicitly here.
  it "does not float a run with no timestamps above a finished one" do
    row = patchset(1, created_at: 2.hours.ago)
    create(:patch_ci_run, patch_branch: row, github_run_id: 100, status: "infra_error",
           queued_at: nil, started_at: nil, completed_at: nil, created_at: 3.hours.ago)
    finished = create(:patch_ci_run, patch_branch: row, github_run_id: 200,
                      completed_at: 5.minutes.ago)

    expect(history.runs_for(row).first.id).to eq(finished.id)
  end

  it "never selects the run payload itself" do
    row = patchset(1, created_at: 1.hour.ago)
    create(:patch_ci_run, patch_branch: row, payload: { "ccache" => { "hit" => 8 } })

    sql = captured_queries { history.patchsets }
    run_queries = sql.select { |q| q.include?("patch_ci_runs") && q.start_with?("SELECT") }

    expect(run_queries).to be_present
    # payload may only ever appear followed by a json extraction operator
    expect(run_queries.none? { |q| q.match?(/payload(?!\s*(#>>|->>))/) }).to be(true)
    # a revert to SELECT * would drop the word "payload" and pass vacuously
    expect(run_queries.none? { |q| q.include?(%("patch_ci_runs".*)) }).to be(true)
  end

  it "reads ccache and the ingest error out of the payload without hauling it" do
    row = patchset(1, created_at: 1.hour.ago)
    create(:patch_ci_run, patch_branch: row,
           payload: { "ccache" => { "hit" => 8412, "miss" => 213 } })

    run = history.runs_for(row).first

    expect(run.ccache_hit).to eq("8412")
    expect(run.ccache_miss).to eq("213")
    expect(run.ingest_error).to be_nil
  end

  it "surfaces the reason a payload was rejected" do
    row = patchset(1, created_at: 1.hour.ago)
    create(:patch_ci_run, patch_branch: row, status: "infra_error",
           payload: { "ingest_error" => "malformed json: unexpected token" })

    expect(history.runs_for(row).first.ingest_error).to eq("malformed json: unexpected token")
  end

  it "does not query runs when the topic has no patchsets" do
    sql = captured_queries { expect(history.patchsets).to eq([]) }

    expect(sql.none? { |q| q.include?("patch_ci_runs") }).to be(true)
  end

  # supersede only fires on a successful push, so "no row superseded yet" is
  # the normal state, and current then rests entirely on the ordering
  it "takes the newest patchset as current when nothing is superseded yet" do
    patchset(1, created_at: 3.days.ago)
    fresh = patchset(2, created_at: 1.hour.ago)

    expect(history.current.id).to eq(fresh.id)
  end

  it "keeps each patchset's runs to itself" do
    first = patchset(1, created_at: 3.days.ago)
    second = patchset(2, created_at: 1.hour.ago)
    first_run = create(:patch_ci_run, patch_branch: first, github_run_id: 100)
    second_run = create(:patch_ci_run, patch_branch: second, github_run_id: 200)

    expect(history.runs_for(first).map(&:id)).to eq([ first_run.id ])
    expect(history.runs_for(second).map(&:id)).to eq([ second_run.id ])
  end
end
