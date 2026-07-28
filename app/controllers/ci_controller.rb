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

    load_aggregates(rows.health, rows.check)
  end

  def branches
    @repo_state = PatchCiRepoState.current
    @query = PatchCi::BranchQuery.new(params: params, repo_state: @repo_state)
    @branches = @query.rows
  end

  def topic
    @topic = Topic.find(params[:id])
    @repo_state = PatchCiRepoState.current
    @history = PatchCi::TopicHistory.new(topic: @topic, repo_state: @repo_state)
  end

  def stats
    @repo_state = PatchCiRepoState.current
    @params_object = PatchCi::StatsParams.new(params: params)
    load_pipeline_stats
    load_corpus_stats
  end

  private

  # every subscriber re-GETs this page on the same broadcast, so the
  # whole-table aggregates are computed once per orchestrator cycle instead of
  # once per client. The row lists stay live - they are cheap, and they are
  # what people watch.
  # takes the request's one BranchHealth and MasterCheck - a second instance
  # would recompute its cutoffs and could disagree with the row labels already
  # rendered. MasterCheck freezes a wall clock, so it has the same hazard.
  def load_aggregates(health, check)
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
        # the intersection, not a third bucket: the outcome says it applied,
        # the tier says we checked that against this master. Either one alone
        # overstates it.
        verified: check.filter(health.scope_for("applies"), [ "current" ]).count,
        # live buckets only, NOT PatchBranch.current - the planner never
        # re-probes a retired row, so the whole corpus puts a permanent and
        # monotonically growing floor under the warning and the all-clear
        # branch becomes dead. Retired rows are split across two buckets:
        # the CASE tests status = 'failed' before base age, so an ancient
        # failed row reads never_applied rather than wont_retry, and excluding
        # only wont_retry would miss the bulk of them. Costs the handful of
        # still-retryable failed rows, which is the cheaper error.
        overdue: check.counts(health.filter(PatchBranch.current, %w[applies needs_rebase awaiting_ci]))
                      .fetch("overdue", 0),
        last24: PatchCiRun.terminal.where("completed_at >= ?", 24.hours.ago).group(:status).count }
    end

    @plan_counts = agg[:plan_counts]
    @wont_retry = agg[:wont_retry]
    @awaiting_not_pushed = agg[:awaiting_not_pushed]
    @awaiting_pushed = agg[:awaiting_pushed]
    @verified = agg[:verified]
    @overdue = agg[:overdue]
    @last24 = agg[:last24]
  end

  # one cache entry per section per param triple, keyed on the repo state's
  # fetched_at like load_aggregates - every reader of a broadcast-refreshed page
  # would otherwise recompute the same whole-table scans
  def load_pipeline_stats
    @pipeline = Rails.cache.fetch([ "ci-stats-pipeline", @repo_state&.fetched_at, @params_object.signature ],
                                  expires_in: PatchCi::Config::AGGREGATE_TTL) do
      PatchCi::RunStats.new(since: @params_object.since, gran: @params_object.gran, now: Time.current).all
    end
  end

  def load_corpus_stats
    @corpus = Rails.cache.fetch([ "ci-stats-corpus", @repo_state&.fetched_at, @params_object.signature ],
                                expires_in: PatchCi::Config::AGGREGATE_TTL) do
      PatchCi::CorpusStats.new(repo_state: @repo_state, active_only: @params_object.active_only?).all
    end
  end
end
