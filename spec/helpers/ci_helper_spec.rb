require "rails_helper"

RSpec.describe CiHelper, type: :helper do
  let(:repo_state) do
    create(:patch_ci_repo_state, master_committed_at: Time.current, master_commit_height: 1_000)
  end

  # base_tier is a select alias on real rows, not a model method, so a
  # verified double cannot stand in for it
  def row(tier, days_behind: nil, base_commit_height: nil)
    base_committed_at = days_behind && repo_state.master_committed_at - days_behind.days
    branch = build(:patch_branch, base_committed_at: base_committed_at,
                   base_commit_height: base_commit_height)
    branch.define_singleton_method(:base_tier) { tier }
    branch
  end

  # all three badge maps fall back silently, and the result facet renders chips
  # through the same fallback - a new value would read as a humanized label in
  # neutral grey on every chip and every row, with chip and badge agreeing, so
  # nothing else here would notice
  it "has a badge for every tier and nothing else" do
    expect(CiHelper::CI_BASE_TIER_BADGES.keys).to match_array(PatchCi::BaseFreshness::TIERS)
  end

  it "has a badge for every run status and nothing else" do
    expect(CiHelper::CI_BADGES.keys).to match_array(PatchCiRun::STATUSES)
  end

  it "has a badge for every health bucket and nothing else" do
    expect(CiHelper::CI_BUCKET_BADGES.keys).to match_array(PatchCi::BranchHealth::BUCKETS)
  end

  describe "#ci_base_tier_badge" do
    it "labels a recent base with a compact day count" do
      html = helper.ci_base_tier_badge(
        row("recent", days_behind: 12, base_commit_height: 904), repo_state
      )

      expect(html).to include("recent")
      expect(html).to include("12d")
      expect(html).to include("96 commits")
      expect(html).to include("b-success")
    end

    it "compacts months for a stale base" do
      html = helper.ci_base_tier_badge(
        row("stale", days_behind: 147, base_commit_height: 900), repo_state
      )

      expect(html).to include("stale")
      expect(html).to include("5mo")
      expect(html).to include("b-rebase")
    end

    it "compacts years for an ancient base" do
      html = helper.ci_base_tier_badge(
        row("ancient", days_behind: 1460, base_commit_height: 100), repo_state
      )

      expect(html).to include("ancient")
      expect(html).to include("4y")
      expect(html).to include("b-buildfail")
    end

    # the badge always carries a title, so it always needs the affordance
    it "marks the badge as hoverable" do
      html = helper.ci_base_tier_badge(row("recent", days_behind: 1), repo_state)

      expect(html).to include("ci-hover")
    end

    it "says so when there is no base metadata" do
      html = helper.ci_base_tier_badge(row("unknown"), repo_state)

      expect(html).to include("unknown")
      expect(html).to include("no base metadata")
      expect(html).to include("b-queued")
    end

    # a repo state fetched mid-push can trail the base it is compared against
    it "does not render a negative behind figure" do
      html = helper.ci_base_tier_badge(
        row("recent", days_behind: -2, base_commit_height: 1_007), repo_state
      )

      expect(html).to include("0d")
      expect(html).to include("0 days / 0 commits behind master")
    end
  end

  # the only place a CI_BADGES css class is pinned - rename one out of step
  # with ci.css and nothing else notices
  describe "#ci_status_badge" do
    it "carries the status css class and label" do
      html = helper.ci_status_badge("tests_failed")

      expect(html).to include("badge b-testsfail")
      expect(html).to include("tests failed")
      expect(html).not_to include("ci-hover")
    end

    it "marks the badge as hoverable when it carries a reason" do
      html = helper.ci_status_badge("infra_error", title: "no verdict after 48h")

      expect(html).to include("ci-hover")
      expect(html).to include("no verdict after 48h")
    end
  end

  describe "#ci_timing_cell" do
    it "counts elapsed minutes for an in-flight row" do
      row = build(:patch_branch, ci_status: "running", pushed_at: 9.minutes.ago)

      expect(helper.ci_timing_cell(row)).to include("9m elapsed")
    end

    # in-flight is a ci_status, and nothing keeps it in step with pushed_at
    it "has nothing to count from when an in-flight row was never pushed" do
      row = build(:patch_branch, ci_status: "running", pushed_at: nil)

      expect(helper.ci_timing_cell(row)).to eq(helper.ci_muted_dash)
    end

    it "shows both durations once a row is terminal" do
      row = build(:patch_branch, ci_status: "success")
      row.latest_run_summary = build(:patch_ci_run, build_seconds: 185, test_seconds: 281)

      expect(helper.ci_timing_cell(row)).to include("3m 05s / 4m 41s")
    end
  end

  describe "#ci_tests_cell" do
    it "is a dash when the row has no run attached" do
      row = build(:patch_branch)
      row.latest_run_summary = nil

      expect(helper.ci_tests_cell(row)).to eq(helper.ci_muted_dash)
    end
  end

  describe "#ci_bucket_badge" do
    it "labels a bucket in lower case with the underscores opened up" do
      html = helper.ci_bucket_badge("never_applied")

      expect(html).to include(">never applied<")
      expect(html).to include("badge b-buildfail")
    end

    it "falls back to the neutral badge for an unknown bucket" do
      expect(helper.ci_bucket_badge("something_else")).to include("badge b-queued")
    end
  end

  describe "#ci_result_cell" do
    it "is a dash for a branch with no CI status" do
      expect(helper.ci_result_cell(build(:patch_branch, ci_status: nil))).to eq(helper.ci_muted_dash)
    end

    it "badges the status" do
      expect(helper.ci_result_cell(build(:patch_branch, ci_status: "success"))).to include("b-success")
    end

    # the reason lives on the branch, and only infra/push failures carry one
    it "hangs the skip reason off an infra failure" do
      row = build(:patch_branch, ci_status: "infra_error", ci_skip_reason: "no verdict after 48h")

      expect(helper.ci_result_cell(row)).to include("no verdict after 48h")
    end

    it "leaves the skip reason off an unrelated status" do
      row = build(:patch_branch, ci_status: "tests_failed", ci_skip_reason: "stale reason")

      expect(helper.ci_result_cell(row)).not_to include("stale reason")
    end
  end

  describe "#ci_image_cell" do
    it "is a dash without a run image" do
      row = build(:patch_branch)
      row.latest_run_summary = nil

      expect(helper.ci_image_cell(row)).to eq(helper.ci_muted_dash)
    end

    it "offers the docker command to copy" do
      row = build(:patch_branch)
      row.latest_run_summary = build(:patch_ci_run, image_ref: "ghcr.io/x/postgres-patch:t1_1-pg18")

      html = helper.ci_image_cell(row)

      expect(html).to include("docker run --rm -p 5432:5432 ghcr.io/x/postgres-patch:t1_1-pg18")
      expect(html).to include("docker run ... :t1_1-pg18")
      expect(html).to include("clipboard")
    end
  end

  # no repo state: nothing these helpers read off the query touches the database
  def query(params = {})
    PatchCi::BranchQuery.new(params: ActionController::Parameters.new(params), repo_state: nil)
  end

  describe "facet chips" do
    it "adds itself to a facet that already has a value" do
      html = helper.ci_facet_chip(query(state: "fresh"), :state, "wont_retry")

      expect(html).to include("state=fresh%2Cwont_retry")
      expect(html).not_to include("is-active")
      # link_to escapes the apostrophe in the shared bucket label
      expect(html).to include(">won&#39;t retry<")
    end

    # an empty facet must leave the url, not linger as state=
    it "drops the facet entirely when the last value is toggled off" do
      html = helper.ci_facet_chip(query(state: "fresh"), :state, "fresh")

      expect(html).to include("is-active")
      expect(html).to include(%(href="/ci/branches"))
      expect(html).not_to include("state=")
    end

    it "drops only its own value from a multi-value facet" do
      html = helper.ci_facet_chip(query(state: "fresh,wont_retry"), :state, "fresh")

      expect(html).to include(%(href="/ci/branches?state=wont_retry"))
    end

    it "leaves the other facets, the search and the sort alone" do
      html = helper.ci_facet_chip(query(base: "recent", q: "vacuum", sort: "pg", dir: "asc"),
                                 :state, "fresh")

      expect(html).to include("base=recent")
      expect(html).to include("q=vacuum")
      expect(html).to include("sort=pg")
      expect(html).to include("dir=asc")
    end

    it "shows a count when it is given one" do
      expect(helper.ci_facet_chip(query, :state, "fresh", count: 1234)).to include("fresh (1,234)")
    end

    # a chip renders inside the frame, so it targets it without saying so
    it "carries no turbo attributes of its own" do
      expect(helper.ci_facet_chip(query, :state, "fresh")).not_to include("data-turbo")
    end

    # colour alone does not reach a screen reader
    it "marks the selected state on the active chip" do
      expect(helper.ci_facet_chip(query(state: "fresh"), :state, "fresh")).to include(%(aria-current="true"))
      expect(helper.ci_facet_chip(query, :state, "fresh")).not_to include("aria-current")
    end

    # the table renders these statuses through CI_BADGES; a chip that spells the
    # raw value contradicts the badge directly under it
    it "labels a result chip the way its badge is labelled" do
      expect(helper.ci_facet_chip(query, :result, "pushed_awaiting_ci")).to include(">waiting for runner<")
      expect(helper.ci_facet_chip(query, :result, "ci_none")).to include(">no CI<")
    end

    # the sentinel is not a run status and must not read like the ci_none one
    it "spells the no-result sentinel out" do
      chip = helper.ci_facet_chip(query, :result, PatchCi::BranchQuery::NO_RESULT)

      expect(chip).to include(">no result<")
    end

    it "marks the all chip active only while its facet is empty" do
      expect(helper.ci_facet_all_chip(query, :state)).to include("is-active")
      expect(helper.ci_facet_all_chip(query(state: "fresh"), :state)).not_to include("is-active")
    end

    it "clears just its own facet from the all chip" do
      html = helper.ci_facet_all_chip(query(state: "fresh", base: "recent"), :state)

      expect(html).to include("base=recent")
      expect(html).not_to include("state=")
    end
  end

  describe "#ci_sort_header" do
    it "flips the direction of the column already sorted" do
      html = helper.ci_sort_header(query, "updated", "Updated", numeric: true)

      expect(html).to include(%(class="num sortable is-active"))
      expect(html).to include(%(aria-sort="descending"))
      expect(html).to include("sort=updated")
      expect(html).to include("dir=asc")
      expect(html).to include(CiHelper::SORT_ARROWS.fetch("desc"))
    end

    it "starts any other column descending and unmarked" do
      html = helper.ci_sort_header(query, "pg", "PG")

      expect(html).to include(%(class="sortable"))
      expect(html).to include("dir=desc")
      expect(html).not_to include(CiHelper::SORT_ARROWS.fetch("desc"))
      expect(html).not_to include("aria-sort")
      expect(html).not_to include("data-turbo")
    end

    # base sorts inverted inside BranchQuery, so its arrow must read like the rest
    it "points the arrow up while the sort is ascending" do
      html = helper.ci_sort_header(query(sort: "base", dir: "asc"), "base", "Base")

      expect(html).to include(CiHelper::SORT_ARROWS.fetch("asc"))
      expect(html).to include(%(aria-sort="ascending"))
      expect(html).to include("dir=desc")
    end

    it "keeps the active facets when re-sorting" do
      html = helper.ci_sort_header(query(state: "fresh"), "pg", "PG")

      expect(html).to include("state=fresh")
    end

    it "is a plain header for the dashboard sections, which have no query" do
      expect(helper.ci_sort_header(nil, "pg", "PG", numeric: true)).to eq(%(<th class="num">PG</th>))
      expect(helper.ci_sort_header(nil, "branch", "Branch")).to eq("<th>Branch</th>")
    end
  end

  describe "#ci_behind_label" do
    it "is nil without a day count" do
      expect(helper.ci_behind_label(nil)).to be_nil
    end

    it "counts days up to two months" do
      expect(helper.ci_behind_label(59)).to eq("59d")
    end

    it "switches to months at two months" do
      expect(helper.ci_behind_label(60)).to eq("2mo")
    end

    it "still counts months just under a year" do
      expect(helper.ci_behind_label(364)).to eq("12mo")
    end

    it "switches to years at a year" do
      expect(helper.ci_behind_label(365)).to eq("1y")
    end
  end
end
