module PatchCi
  # One CASE expression, three consumers: dashboard counts, per-row labels,
  # /ci/branches filters. Keeping it in SQL keeps the three in agreement.
  #
  # Deliberate divergences from Planner (do not "fix" these to match Planner
  # exactly, they read different questions):
  # (a) last_master_apply_at is a WHEN-to-retry guard, not a does-work-exist
  #     one. A row with master_apply_error stays needs_rebase here for display
  #     even while Planner is waiting for master to move before retrying it.
  # (b) awaiting_ci outranks staleness for queued/running rows here, same as
  #     Planner's in-flight exclusion from the rebase tier - a force-push
  #     would burn the running CI slot, so neither of us touches it yet.
  class BranchHealth
    BUCKETS = %w[fresh needs_rebase awaiting_ci wont_retry never_applied].freeze

    def initialize(repo_state: PatchCiRepoState.current)
      @repo_state = repo_state
    end

    # the counts every page shows. One owner, so the dashboard and /ci/branches
    # cannot key the same numbers differently and drift apart. Keyed on the repo
    # state because these are whole-table aggregates recomputed per fetch cycle.
    def cached_counts
      @cached_counts ||= Rails.cache.fetch([ "ci-health-counts", @repo_state&.fetched_at ],
                                           expires_in: Config::AGGREGATE_TTL) { counts }
    end

    # memoized: one instance = one request = one consistent snapshot (a
    # second call must not recompute cutoffs and disagree with the first)
    def counts
      @counts ||= base_scope.group(Arel.sql(bucket_sql)).count
                             .transform_keys(&:to_s)
                             .then { |h| BUCKETS.index_with { |b| h.fetch(b, 0) } }
    end

    def scope_for(bucket)
      bucket = bucket.to_s
      raise ArgumentError, "unknown bucket: #{bucket.inspect}" unless BUCKETS.include?(bucket)
      base_scope.where("#{bucket_sql} = ?", bucket)
    end

    # no production caller: this is the oracle ~18 with_bucket/scope_for
    # examples check the CASE against one row at a time. Do not delete it as
    # dead code - the spec file goes with it.
    def bucket_for(row)
      base_scope.where(id: row.id).pick(Arel.sql(bucket_sql))
    end

    # several buckets at once, on a caller's relation - scope_for covers the
    # single-bucket case off base_scope. Mirrors BaseFreshness#filter.
    def filter(relation, buckets)
      buckets = Array(buckets).map(&:to_s) & BUCKETS
      return relation if buckets.empty?
      relation.joins(:topic).where("#{bucket_sql} IN (?)", buckets)
    end

    def wont_retry_breakdown
      scope_for("wont_retry")
        .group(Arel.sql(wont_retry_reason_sql)).count
        .sort_by { |_, c| -c }.to_h
    end

    # rows plus a health_bucket column, in one query - every list that renders
    # the shared table goes through here (/ci/branches and both /ci dashboard
    # sections, via BranchRows), so N rows do not cost N bucket_for round trips
    def with_bucket(relation = base_scope)
      # bucket_sql references topics; joins is deduped when already present
      relation.joins(:topic)
              .select(PatchBranch.arel_table[Arel.star], Arel.sql("(#{bucket_sql}) AS health_bucket"))
    end

    private

    # memoized alongside counts/bucket_for/scope_for for the same reason:
    # one instance, one set of cutoffs
    def bucket_sql
      @bucket_sql ||= begin
        # same boundary BaseFreshness draws between recent and stale, read as
        # a yes/no instead of a tier. Without a repo state there is nothing to
        # measure against, so WORK_FROM is the floor - a pre-2017 base still
        # reads stale. BaseFreshness falls back to 'unknown' instead; both are
        # deliberate and spec-pinned.
        stale_cutoff = @repo_state ? @repo_state.master_committed_at - Config::REBASE_AFTER_DAYS.days : Config::WORK_FROM
        ActiveRecord::Base.sanitize_sql_array(
          [ <<~SQL, active_cutoff: Config::ACTIVE_THREAD_DAYS.days.ago, stale_cutoff: stale_cutoff ])
          CASE
            WHEN patch_branches.ci_status = 'ci_none'
              OR EXISTS (SELECT 1 FROM commit_topics ct WHERE ct.topic_id = patch_branches.topic_id)
              THEN 'wont_retry'
            WHEN patch_branches.status = 'failed' THEN
              CASE WHEN patch_branches.failure_stage IN ('apply', 'base_detection')
                        AND topics.merged_into_topic_id IS NULL
                        AND topics.last_message_at >= :active_cutoff
                   THEN 'needs_rebase' ELSE 'never_applied' END
            WHEN patch_branches.pushed_at IS NULL THEN 'awaiting_ci'
            WHEN patch_branches.ci_status IN (#{in_flight_list})
              THEN 'awaiting_ci'
            WHEN patch_branches.master_apply_error IS NOT NULL
              OR patch_branches.base_committed_at < :stale_cutoff
              OR patch_branches.base_committed_at IS NULL THEN
              CASE WHEN topics.merged_into_topic_id IS NULL
                        AND topics.last_message_at >= :active_cutoff
                   THEN 'needs_rebase' ELSE 'wont_retry' END
            ELSE 'fresh'
          END
        SQL
      end
    end

    def base_scope
      PatchBranch.current.joins(:topic)
    end

    # literals from a frozen constant, never user input
    def in_flight_list
      PatchCiRun::IN_FLIGHT_BRANCH_STATUSES.map { |status| "'#{status}'" }.join(", ")
    end

    def wont_retry_reason_sql
      <<~SQL
        CASE
          WHEN patch_branches.ci_status = 'ci_none' THEN coalesce(patch_branches.ci_skip_reason, 'ci_none')
          WHEN EXISTS (SELECT 1 FROM commit_topics ct WHERE ct.topic_id = patch_branches.topic_id)
            THEN 'committed'
          ELSE 'thread inactive'
        END
      SQL
    end
  end
end
