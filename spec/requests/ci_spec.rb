# frozen_string_literal: true

require "rails_helper"

RSpec.describe "CI dashboard", type: :request do
  # lets an example assert a plain string lands in the right section instead of
  # anywhere on the page. Parsed, not sliced: the tab panels are divs, so there
  # is no closing tag a regex could stop at
  def section(id)
    Nokogiri::HTML(response.body).at_css("##{id}").to_html
  end

  # th texts with any sort link and direction arrow stripped, so the dashboard's
  # plain headers and the branches page's sortable ones compare equal
  def header_labels(body)
    body[/<tr><th>Result.*?<\/tr>/m].to_s.scan(/<th[^>]*>(.*?)<\/th>/m)
       .map { |(cell)| cell.gsub(/<[^>]+>/, "").delete(CiHelper::SORT_ARROWS.values.join).strip }
  end

  # header row plus the first data row of the shared table, so an example can
  # name a column instead of hoping a string lands in the right cell
  def first_table_row(body)
    rows = Nokogiri::HTML(body).at_css("table.ci-table").css("tr")
    headers = rows.first.css("th").map do |th|
      th.text.delete(CiHelper::SORT_ARROWS.values.join).strip
    end
    [ headers, rows[1].css("td") ]
  end

  def branch_with_run(branch_attrs = {}, run_attrs = {})
    branch = create(:patch_branch, **branch_attrs)
    run = create(:patch_ci_run, patch_branch: branch, **run_attrs)
    branch.update!(latest_ci_run: run)
    [ branch, run ]
  end

  describe "GET /ci" do
    it "renders the empty state for guests" do
      get "/ci"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("orchestrator not running")
      expect(response.body).to include("nothing running")
      expect(response.body).to include("plan is empty")
      expect(response.body).to include("no branches yet")
      expect(response.body).to include("Branch health")
    end

    it "links CI from both nav menus" do
      get "/ci"

      expect(response.body.scan(%r{<a[^>]+href="/ci"[^>]*>CI</a>}).size).to eq(2)
    end

    it "shows the heartbeat as running while the repo state is fresh" do
      create(:patch_ci_repo_state, master_sha: "bf12ac9de" + "0" * 31, fetched_at: 10.seconds.ago)

      get "/ci"

      expect(response.body).to include("ci-up")
      expect(response.body).not_to include("orchestrator not running")
      expect(response.body).to include("bf12ac9de")
    end

    it "shows the heartbeat as down when the last cycle is stale" do
      create(:patch_ci_repo_state, fetched_at: 30.minutes.ago)

      get "/ci"

      expect(response.body).to include("orchestrator not running")
      expect(response.body).to include("ago")
    end

    it "renders every section with data" do
      create(:patch_ci_repo_state)
      topic = create(:topic, last_message_at: Time.current)
      msg = create(:message, topic: topic, created_at: 1.day.ago, is_patch_submission: true)
      running = create(:patch_branch, topic: topic, pushed_at: 1.hour.ago, ci_status: "running")
      row, = branch_with_run(
        { topic: topic, message: msg, pushed_at: 2.hours.ago, ci_status: "tests_failed",
          base_committed_at: 2.days.ago, base_commit_height: 10 },
        { status: "tests_failed", pg_major: 18, completed_at: 5.minutes.ago, tests_total: 229,
          failed_tests: [ "regress/self_contradictory" ],
          build_seconds: 185, test_seconds: 281,
          image_ref: "ghcr.io/hackorum-dev/postgres-patch:t1" }
      )

      get "/ci"

      expect(response).to have_http_status(:ok)
      expect(section("in-progress")).to include(running.branch_name)
      expect(section("in-progress")).to include("60m elapsed")
      expect(response.body).to include(topic.title)
      # section-scoped: "tests failed" also appears in the last-24h strip
      recent = section("recent")
      expect(recent).to include(row.branch_name)
      expect(recent).to include("tests failed")
      expect(recent).to include("228 / 229")
      expect(recent).to include(%(title="Failed: regress/self_contradictory"))
      expect(recent).to include("3m 05s / 4m 41s")
      expect(recent).to include("docker run")
      # last 24h summary
      expect(response.body).to include("1 runs")
      # one scroll region per section, each named for its own section
      expect(section("in-progress")).to include(%(aria-label="In progress branches"))
      expect(recent).to include(%(aria-label="Recent results"))
    end

    # the labels have to match where they land: "all branches" under a filtered
    # preset, or "full plan" over a page Planner has no say in, both lie
    it "sends the sidebar nav to the unfiltered branch table" do
      get "/ci"

      nav = Nokogiri::HTML(response.body).at_css(".layout-sidebar").to_html
      expect(nav).to match(%r{href="/ci/branches"[^>]*>All branches<})
    end

    it "renders the three lists as tabs, the first one selected" do
      get "/ci"
      doc = Nokogiri::HTML(response.body)

      tabs = doc.css(".ci-tab")
      expect(tabs.map { |tab| tab.text.strip }).to eq([ "In progress", "Up next", "Recent results" ])
      expect(tabs.map { |tab| tab["aria-selected"] }).to eq([ "true", "false", "false" ])
      # every tab points at a panel that is on the page
      panels = doc.css(".ci-tab-panel").map { |panel| panel["id"] }
      expect(tabs.map { |tab| tab["aria-controls"] }).to eq(panels)
      expect(panels).to eq([ "in-progress", "up-next", "recent" ])
      expect(doc.css(".ci-tab-panel.is-active").size).to eq(1)
    end

    # a broadcast refresh morphs the page, and the server always marks the first
    # tab active - without the controller the reader is thrown back to it
    it "wires the tabs for morph refreshes" do
      get "/ci"

      expect(response.body).to include(%(data-controller="tabs tabs-morph"))
    end

    it "sends branch health to the recent-ish preset" do
      get "/ci"

      expect(section("health")).to include(%(href="/ci/branches?base=recent%2Cstale"))
      expect(section("health")).to include(">recent branches<")
    end

    it "lists an unapplied patch version in the forecast" do
      create(:patch_ci_repo_state)
      topic = create(:topic, last_message_at: Time.current)
      create(:message, topic: topic, created_at: 30.minutes.ago, is_patch_submission: true)

      get "/ci"

      expect(response.body).to include("new version")
      expect(response.body).to include("patch posted 30 minutes ago")
      expect(response.body).to include("apply + push")
    end

    it "clamps the passed test count at zero" do
      create(:patch_ci_repo_state)
      topic = create(:topic, last_message_at: Time.current)
      branch_with_run({ topic: topic, pushed_at: 2.hours.ago, ci_status: "tests_failed" },
                      { status: "tests_failed", completed_at: 1.hour.ago,
                        tests_total: 2, failed_tests: [ "a", "b", "c" ] })

      get "/ci"

      expect(response.body).to include("0 / 2")
    end

    it "surfaces the branch skip reason on an infra error badge" do
      create(:patch_ci_repo_state)
      topic = create(:topic, last_message_at: Time.current)
      branch_with_run({ topic: topic, pushed_at: 3.days.ago, ci_status: "infra_error",
                        ci_skip_reason: "no verdict after 48h" },
                      { status: "infra_error", completed_at: 1.hour.ago })

      get "/ci"

      expect(response.body).to include("infra error")
      expect(response.body).to include("no verdict after 48h")
      # a run without an image ref offers nothing to copy
      expect(response.body).not_to include("docker run")
    end

    it "splits the awaiting CI bucket by pushed state" do
      create(:patch_ci_repo_state)
      topic = create(:topic, last_message_at: Time.current)
      create(:patch_branch, topic: topic, pushed_at: nil)
      create(:patch_branch, topic: topic, pushed_at: nil)
      other = create(:topic, last_message_at: Time.current)
      create(:patch_branch, topic: other, pushed_at: 5.minutes.ago, ci_status: "queued")

      get "/ci"

      # counts pinned, so a flipped grouped-count key cannot pass silently
      expect(response.body).to match(%r{not yet pushed</span>\s*<span>2</span>})
      expect(response.body).to match(%r{pushed, awaiting verdict</span>\s*<span>1</span>})
    end

    it "honours the in-progress list limit" do
      stub_const("PatchCi::Config::IN_PROGRESS_LIST", 1)
      create(:patch_ci_repo_state)
      topic = create(:topic, last_message_at: Time.current)
      # the list orders by updated_at. Created first (so id DESC disagrees) and
      # pushed last (so pushed_at DESC disagrees too) - either revert now fails
      # instead of passing on creation order
      newer = create(:patch_branch, topic: topic, pushed_at: 2.hours.ago, ci_status: "running",
                     updated_at: 5.minutes.ago)
      older = create(:patch_branch, topic: topic, pushed_at: 5.minutes.ago, ci_status: "running",
                     updated_at: 2.hours.ago)

      get "/ci"

      expect(response.body).to include(newer.branch_name)
      expect(response.body).not_to include(older.branch_name)
      expect(response.body).to include("1 of 2 shown")
    end

    it "honours the recent results limit" do
      stub_const("PatchCi::Config::RECENT_LIST", 1)
      create(:patch_ci_repo_state)
      topic = create(:topic, last_message_at: Time.current)
      # created first and pushed last, so neither id DESC nor pushed_at DESC
      # reproduces the expected order by accident
      newer = create(:patch_branch, topic: topic, ci_status: "build_failed", pushed_at: 3.hours.ago,
                     updated_at: 1.minute.ago)
      older = create(:patch_branch, topic: topic, ci_status: "success", pushed_at: 1.minute.ago,
                     updated_at: 3.hours.ago)

      get "/ci"

      expect(response.body).to include(newer.branch_name)
      expect(response.body).not_to include(older.branch_name)
    end

    it "does not load run payloads into the dashboard" do
      create(:patch_ci_repo_state)
      branch_with_run({ topic: create(:topic, last_message_at: Time.current),
                        ci_status: "success", pushed_at: 1.hour.ago },
                      { status: "success", completed_at: 1.hour.ago,
                        payload: { secret: "x" * 100 } })

      queries = []
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        queries << payload[:sql]
      end
      get "/ci"
      ActiveSupport::Notifications.unsubscribe(sub)

      run_queries = queries.select { |q| q.include?("patch_ci_runs") && q.start_with?("SELECT") }
      expect(run_queries).to be_present
      expect(run_queries.none? { |q| q.include?("payload") }).to be(true)
      # a revert to SELECT * would drop the word "payload" and pass vacuously
      expect(run_queries.none? { |q| q.include?(%("patch_ci_runs".*)) }).to be(true)
    end

    it "shows elapsed time instead of durations for an in-flight row" do
      create(:patch_ci_repo_state)
      row = create(:patch_branch, ci_status: "running", pushed_at: 14.minutes.ago)

      get "/ci"

      expect(response.body).to include(row.branch_name)
      expect(response.body).to include("14m elapsed")
    end

    # one partial feeds both, but only the branches page turns four headers into
    # sort links - so compare the column labels rather than the markup
    it "renders the same columns as the branches page" do
      create(:patch_ci_repo_state)
      create(:patch_branch, ci_status: "success", pushed_at: 1.hour.ago)

      get "/ci"
      dashboard = header_labels(response.body)

      get "/ci/branches"

      expect(dashboard).to eq([ "Result", "Branch", "Topic", "PG", "Base", "State",
                                "Tests", "Timing", "Try it", "Updated" ])
      expect(header_labels(response.body)).to eq(dashboard)
    end

    it "keeps in-flight rows out of recent results" do
      create(:patch_ci_repo_state)
      running = create(:patch_branch, ci_status: "running", pushed_at: 5.minutes.ago)
      done = create(:patch_branch, ci_status: "success", pushed_at: 1.hour.ago)

      get "/ci"

      # both appear on the page; only the terminal one is under #recent
      expect(section("recent")).to include(done.branch_name)
      expect(section("recent")).not_to include(running.branch_name)
    end

    # recent results moved from PatchCiRun.terminal to PatchBranch.current, so a
    # v1 row's result stops showing once v2 supersedes it. Intended - pinned so
    # a lost .current does not quietly bring the old verdicts back.
    it "leaves a superseded branch out of recent results" do
      create(:patch_ci_repo_state)
      current = create(:patch_branch, ci_status: "success", pushed_at: 10.minutes.ago)
      old = create(:patch_branch, ci_status: "tests_failed", pushed_at: 1.hour.ago,
                   superseded_by: current)

      get "/ci"

      expect(section("recent")).to include(current.branch_name)
      expect(section("recent")).not_to include(old.branch_name)
    end

    it "shows the base freshness tier on dashboard rows" do
      state = create(:patch_ci_repo_state, master_committed_at: Time.current)
      create(:patch_branch, ci_status: "success", pushed_at: 1.hour.ago,
             base_committed_at: state.master_committed_at - 400.days, base_commit_height: 5)

      get "/ci"

      expect(response.body).to include("ancient")
    end
  end

  describe "GET /ci/runs" do
    it "is gone" do
      get "/ci/runs"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /ci/branches" do
    it "renders for guests" do
      get "/ci/branches"
      expect(response).to have_http_status(:ok)
    end

    # every other cell assertion here is "this string is somewhere in this
    # section", which a td inserted, dropped or swapped without touching the th
    # list would still satisfy. One partial, so this covers all three tables.
    it "lines the cells up with the headers" do
      create(:patch_ci_repo_state)
      branch_with_run({ pg_major: 18, ci_status: "tests_failed", pushed_at: 1.hour.ago },
                      { status: "tests_failed", pg_major: 18 })

      get "/ci/branches"
      headers, cells = first_table_row(response.body)

      expect(cells.size).to eq(headers.size)
      expect(cells[headers.index("PG")].text.strip).to eq("18")
      expect(cells[headers.index("Result")].text.strip).to eq("tests failed")
    end

    it "renders the search box, the facet rows and the table frame" do
      create(:patch_ci_repo_state)
      create(:patch_branch, pg_major: 18)

      get "/ci/branches"

      expect(response.body).to include("ci-search")
      expect(response.body).to include("ci-facets")
      expect(response.body).to include(%(id="ci-branches"))
      # one chip per facet value, so all four rows are wired to the query
      expect(response.body).to include(%(href="/ci/branches?base=recent"))
      expect(response.body).to include(%(href="/ci/branches?state=fresh"))
      expect(response.body).to include(%(href="/ci/branches?pg=18"))
      expect(response.body).to include(%(href="/ci/branches?result=success"))
      # a sortable header on a column that is not the current sort
      expect(response.body).to include(%(href="/ci/branches?dir=desc&amp;sort=pg"))
    end

    # rendered outside the frame, the chips and the form's hidden fields would
    # still hold the previous request's params after a frame navigation, and the
    # next click would drop whatever the last one added
    it "keeps the whole chrome inside the table frame" do
      # two pages, so kaminari renders a pager to find in there
      stub_const("PatchCi::Config::BRANCHES_PAGE", 1)
      create(:patch_ci_repo_state)
      2.times { create(:patch_branch) }

      get "/ci/branches"

      frame = response.body[/<turbo-frame [^>]*id="ci-branches".*?<\/turbo-frame>/m]
      expect(frame).not_to be_nil
      expect(frame).to include(%(<form class="ci-search"))
      expect(frame).to include(%(<div class="ci-facets">))
      expect(frame).to include(%(<table class="ci-table">))
      expect(frame).to include(%(<nav class="pagination"))
      # frame-level, so kaminari's own links advance the address bar too
      expect(frame).to match(/\A<turbo-frame [^>]*data-turbo-action="advance"/)
    end

    # the mechanism by which a search keeps the facets that are already applied
    it "carries the active facets and sort through the search form" do
      create(:patch_ci_repo_state)

      get "/ci/branches", params: { base: "recent", state: "fresh", sort: "pg", dir: "asc" }

      form = response.body[/<form class="ci-search".*?<\/form>/m]
      expect(form).to include(%(<input type="hidden" name="base" value="recent"))
      expect(form).to include(%(<input type="hidden" name="state" value="fresh"))
      expect(form).to include(%(<input type="hidden" name="sort" value="pg"))
      expect(form).to include(%(<input type="hidden" name="dir" value="asc"))
      # exactly one q, the visible one
      expect(form.scan(/name="q"/).size).to eq(1)
    end

    # the frame render replaces the form, so the input has to be carried over or
    # the debounced submit eats the caret every 300ms
    it "marks the search box permanent so a frame render keeps the caret" do
      get "/ci/branches"

      expect(response.body).to match(/<input[^>]*id="ci-q"[^>]*data-turbo-permanent/)
    end

    # turbo carries a permanent element across drive renders too, so only a real
    # browser navigation empties the search box
    it "clears filters with turbo declining the link" do
      get "/ci/branches", params: { state: "fresh" }

      expect(response.body).to match(%r{data-turbo="false"[^>]*href="/ci/branches">clear filters})
    end

    it "toggles a facet value instead of replacing the filter" do
      create(:patch_ci_repo_state)
      create(:patch_branch)

      get "/ci/branches", params: { state: "fresh" }

      # an inactive chip adds itself to what is already selected
      expect(response.body).to include(%(href="/ci/branches?state=fresh%2Cwont_retry"))
      # the active chip drops its own value, leaving no empty state= behind
      expect(response.body).to match(%r{is-active[^>]*href="/ci/branches">fresh})
      expect(response.body).to include("clear filters")
    end

    it "offers no clear filters link when nothing is filtered" do
      get "/ci/branches"

      expect(response.body).not_to include("clear filters")
    end

    # a sort is not a filter, and there is nothing to clear on a page that only
    # changed its column order
    it "offers no clear filters link for a sort alone" do
      get "/ci/branches", params: { sort: "pg", dir: "asc" }

      expect(response.body).not_to include("clear filters")
    end

    # the chips are run statuses, and the badges under them come from CI_BADGES
    it "labels result chips the way the table labels the same statuses" do
      get "/ci/branches"

      expect(response.body).to include(">waiting for runner<")
      expect(response.body).not_to include(">pushed awaiting ci<")
      expect(response.body).to include(">no CI<")
      # the NO_RESULT sentinel is not a status and must not read like one
      expect(response.body).to include(">no result<")
      expect(response.body).not_to include(">ci none<")
    end

    it "filters by base tier" do
      create(:patch_ci_repo_state, master_committed_at: Time.current)
      recent = create(:patch_branch, base_committed_at: 1.day.ago, base_commit_height: 10)
      ancient = create(:patch_branch, base_committed_at: 400.days.ago, base_commit_height: 5)

      get "/ci/branches", params: { base: "recent" }

      expect(response.body).to include(recent.branch_name)
      expect(response.body).not_to include(ancient.branch_name)
      expect(response.body).to include("showing 1 of 1 branches")
    end

    it "filters by state" do
      create(:patch_ci_repo_state)
      fresh = create(:patch_branch, pushed_at: 1.day.ago, ci_status: "success",
                     base_committed_at: 1.day.ago, base_commit_height: 10)
      failed = create(:patch_branch, status: "failed", failure_stage: "apply")

      get "/ci/branches", params: { state: "fresh" }

      expect(response.body).to include(fresh.branch_name)
      expect(response.body).not_to include(failed.branch_name)
    end

    it "ignores an unknown state filter" do
      fresh = create(:patch_branch, pushed_at: 1.day.ago, ci_status: "success",
                     base_committed_at: 1.day.ago, base_commit_height: 10)

      get "/ci/branches", params: { state: "not_a_bucket" }

      expect(response.body).to include(fresh.branch_name)
      expect(response.body).not_to include("clear filters")
    end

    it "searches by topic title" do
      create(:patch_ci_repo_state)
      hit = create(:patch_branch, topic: create(:topic, title: "pg_upgrade cleanup"))
      miss = create(:patch_branch, topic: create(:topic, title: "vacuum tuning"))

      get "/ci/branches", params: { q: "upgra" }

      expect(response.body).to include(hit.branch_name)
      expect(response.body).not_to include(miss.branch_name)
      # the search survives a facet click
      expect(response.body).to include(%(href="/ci/branches?q=upgra&amp;state=fresh"))
    end

    it "sorts by a requested column in both directions" do
      create(:patch_ci_repo_state)
      # updated_at runs opposite to pg_major, so the default sort cannot pass this
      high = create(:patch_branch, pg_major: 20, updated_at: 2.hours.ago)
      low = create(:patch_branch, pg_major: 15, updated_at: 1.hour.ago)

      get "/ci/branches", params: { sort: "pg", dir: "desc" }

      expect(response.body.index(high.branch_name)).to be < response.body.index(low.branch_name)

      get "/ci/branches", params: { sort: "pg", dir: "asc" }

      expect(response.body.index(low.branch_name)).to be < response.body.index(high.branch_name)
    end

    it "does not 500 on a huge page number" do
      get "/ci/branches", params: { page: "99999999999999999999" }
      expect(response).to have_http_status(:ok)
    end

    # a NUL is valid UTF-8, so check_param_encoding does not catch it and it
    # reaches quote_string, which raises
    it "does not 500 on a NUL in the search box" do
      get "/ci/branches", params: { q: "a#{0.chr}b" }
      expect(response).to have_http_status(:ok)
    end

    it "paginates" do
      stub_const("PatchCi::Config::BRANCHES_PAGE", 1)
      # newer created first, so id DESC alone would put it on page 2
      newer = create(:patch_branch, updated_at: 1.hour.ago)
      older = create(:patch_branch, updated_at: 2.hours.ago)

      get "/ci/branches"
      expect(response.body).to include(newer.branch_name)
      expect(response.body).not_to include(older.branch_name)

      get "/ci/branches", params: { page: 2 }
      expect(response.body).to include(older.branch_name)
    end

    it "keeps an active filter across pages" do
      stub_const("PatchCi::Config::BRANCHES_PAGE", 1)
      create(:patch_ci_repo_state, master_committed_at: Time.current)
      older = create(:patch_branch, updated_at: 2.hours.ago,
                     base_committed_at: 1.day.ago, base_commit_height: 10)
      newer = create(:patch_branch, updated_at: 1.hour.ago,
                     base_committed_at: 1.day.ago, base_commit_height: 10)
      ancient = create(:patch_branch, base_committed_at: 400.days.ago, base_commit_height: 5)

      get "/ci/branches", params: { base: "recent" }

      expect(response.body).to include(newer.branch_name)
      expect(response.body).to include("showing 1 of 2 branches")
      expect(response.body).to include(%(href="/ci/branches?base=recent&amp;page=2"))

      get "/ci/branches", params: { base: "recent", page: 2 }

      expect(response.body).to include(older.branch_name)
      expect(response.body).not_to include(newer.branch_name)
      expect(response.body).not_to include(ancient.branch_name)
    end

    it "loads branch rows with a single query against patch_branches" do
      create(:patch_ci_repo_state)
      5.times { create(:patch_branch) }

      queries = []
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        queries << payload[:sql]
      end
      get "/ci/branches"
      ActiveSupport::Notifications.unsubscribe(sub)

      # health_bucket only appears on the with_bucket row-select - an N+1
      # reimplementation (bucket_for per row) would show up as several of these
      row_selects = queries.select do |q|
        q.start_with?("SELECT") && q.include?(%("patch_branches")) && q.include?("health_bucket")
      end
      expect(row_selects.size).to eq(1)
    end
  end
end
