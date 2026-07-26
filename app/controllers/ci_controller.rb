class CiController < ApplicationController
  skip_before_action :require_authentication, raise: false

  def index
    @repo_state = PatchCiRepoState.current
    rows = PatchCi::BranchRows.new(repo_state: @repo_state)

    in_flight = PatchBranch.current.ci_in_flight
    @in_flight_count = in_flight.count
    # loaded, so the header can size it without a second count query
    @in_progress = rows.load(in_flight.order(updated_at: :desc, id: :desc)
                                     .limit(PatchCi::Config::IN_PROGRESS_LIST))

    @up_next = PatchCi::Planner.new(repo_state: @repo_state)
                               .plan(limit: PatchCi::Config::UP_NEXT_LIST)

    # terminal only: the in-flight rows are already in the section above
    @recent = rows.load(PatchBranch.current.ci_terminal
                                   .order(updated_at: :desc, id: :desc)
                                   .limit(PatchCi::Config::RECENT_LIST))

    load_aggregates(rows.health)
  end

  def branches
    @repo_state = PatchCiRepoState.current
    @query = PatchCi::BranchQuery.new(params: params, repo_state: @repo_state)
    @branches = @query.rows
  end

  private

  # every subscriber re-GETs this page on the same broadcast, so the
  # whole-table aggregates are computed once per orchestrator cycle instead of
  # once per client. The row lists stay live - they are cheap, and they are
  # what people watch.
  # takes the request's one BranchHealth - a second instance would recompute
  # its cutoffs and could disagree with the row labels already rendered
  def load_aggregates(health)
    # not folded into the agg below: a second copy would expire on its own
    # schedule and disagree with /ci/branches
    @health_counts = health.cached_counts

    agg = Rails.cache.fetch([ "ci-dashboard", @repo_state&.fetched_at ],
                            expires_in: PatchCi::Config::AGGREGATE_TTL) do
      # one scan, two numbers: grouped counts omit empty keys, hence the fetches
      awaiting = health.scope_for("awaiting_ci")
                       .group(Arel.sql("patch_branches.pushed_at IS NULL")).count
      { plan_counts: PatchCi::Planner.new(repo_state: @repo_state).counts,
        wont_retry: health.wont_retry_breakdown,
        awaiting_not_pushed: awaiting.fetch(true, 0),
        awaiting_pushed: awaiting.fetch(false, 0),
        last24: PatchCiRun.terminal.where("completed_at >= ?", 24.hours.ago).group(:status).count }
    end

    @plan_counts = agg[:plan_counts]
    @wont_retry = agg[:wont_retry]
    @awaiting_not_pushed = agg[:awaiting_not_pushed]
    @awaiting_pushed = agg[:awaiting_pushed]
    @last24 = agg[:last24]
  end
end
