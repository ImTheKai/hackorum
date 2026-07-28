module PatchCi
  # How recently this row was tried against master. Deliberately separate from
  # BranchHealth, which answers "what did the last attempt say" - this one
  # answers "how much should you trust that answer". Same with_tier/filter/
  # counts shape as BaseFreshness so /ci/branches can treat it as a facet.
  class MasterCheck
    TIERS = %w[current behind overdue never].freeze

    def initialize(repo_state: PatchCiRepoState.current)
      @repo_state = repo_state
    end

    # selects the star too, for the same reason BaseFreshness does: a bare
    # select() would drop the row's own columns and the row would raise
    # MissingAttributeError at render time
    def with_tier(relation)
      relation.select(PatchBranch.arel_table[Arel.star], Arel.sql("(#{tier_sql}) AS check_tier"))
    end

    def filter(relation, tiers)
      tiers = Array(tiers).map(&:to_s) & TIERS
      return relation if tiers.empty?
      relation.where("#{tier_sql} IN (?)", tiers)
    end

    # Rows a re-probe could tell us something new about: master has moved since
    # the last probe AND the throttle has expired. Sole owner of "due", so a
    # second copy of the clause cannot drift from Planner#rebase_scope, which is
    # its only caller - the dashboard reports the rebase tier's own depth.
    #
    # Not a TIERS value: 'current' already means "master has not moved", but
    # 'behind' spans both sides of the throttle, so due is a narrower question
    # than any single tier answers.
    #
    # Without a repo state there is no master to compare against, so nothing is
    # due - unlike tier_sql, which claims 'never'. Planner returns no plan at
    # all in that state, and this agrees with it.
    def due(relation)
      return relation.none unless @repo_state

      relation.where("patch_branches.last_master_apply_at IS NULL" \
                     " OR (patch_branches.last_master_apply_at < :master_at" \
                     " AND patch_branches.last_master_apply_at < :probe_cutoff)",
                     master_at: @repo_state.master_committed_at,
                     probe_cutoff: Config::MASTER_CHECK_AFTER_HOURS.hours.ago)
    end

    # no repo state means every row is 'never' (see tier_sql), handled before
    # grouping: a bare string constant in GROUP BY is an ordinal reference to
    # Postgres, not a literal
    def counts(relation)
      return TIERS.index_with { 0 }.merge("never" => relation.count) unless @repo_state
      found = relation.group(Arel.sql(tier_sql)).count.transform_keys(&:to_s)
      TIERS.index_with { |tier| found.fetch(tier, 0) }
    end

    private

    # memoized: one instance = one request = one consistent snapshot. Unlike
    # BaseFreshness's, this memo also freezes a wall clock, since warn_cutoff
    # is relative to now - that is the point, with_tier/filter/counts on one
    # instance must not disagree about where the window fell.
    #
    # The no-repo-state fallback overstates, knowingly: 'never' is a claim
    # about the row, where BaseFreshness's 'unknown' says "cannot measure", so
    # a row with last_master_apply_at set still reports as never probed. There
    # is no unknown tier to fall back to and nothing else on the page is
    # trustworthy in that state either. Deliberate and spec-pinned.
    def tier_sql
      @tier_sql ||= @repo_state ? dated_sql : "'never'"
    end

    # "master moved since the probe" is the >= :master_at test, not a separate
    # clause: a probe newer than master's own commit time cannot be improved by
    # re-running it, so a frozen master reads current forever and never raises
    # a false overdue.
    def dated_sql
      ActiveRecord::Base.sanitize_sql_array(
        [ <<~SQL, master_at: @repo_state.master_committed_at, warn_cutoff: warn_cutoff ]
          CASE
            WHEN patch_branches.last_master_apply_at IS NULL THEN 'never'
            WHEN patch_branches.last_master_apply_at >= :master_at THEN 'current'
            WHEN patch_branches.last_master_apply_at < :warn_cutoff THEN 'overdue'
            ELSE 'behind'
          END
        SQL
      )
    end

    # wall clock, not master's commit time: this is "how long since we last
    # looked", which the daily sweep is measured against
    def warn_cutoff
      Config::MASTER_CHECK_WARN_HOURS.hours.ago
    end
  end
end
