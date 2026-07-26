module PatchCi
  # How old is the master this patchset was applied on. Deliberately separate
  # from BranchHealth: that one answers "will the orchestrator do something
  # about this row", this one answers "can I trust the result against today's
  # master". Same with_*/filter shape for the same reason - the tier has to be
  # filterable, not just renderable.
  class BaseFreshness
    TIERS = %w[recent stale ancient unknown].freeze

    def initialize(repo_state: PatchCiRepoState.current)
      @repo_state = repo_state
    end

    # selects the star too, so this works standalone and not just composed
    # onto BranchHealth#with_bucket - a bare select() would drop it and the
    # row would raise MissingAttributeError at render time
    def with_tier(relation)
      relation.select(PatchBranch.arel_table[Arel.star], Arel.sql("(#{tier_sql}) AS base_tier"))
    end

    def filter(relation, tiers)
      tiers = Array(tiers).map(&:to_s) & TIERS
      return relation if tiers.empty?
      relation.where("#{tier_sql} IN (?)", tiers)
    end

    private

    def tier_sql
      @tier_sql ||= @repo_state ? dated_sql : "'unknown'"
    end

    # the recent/stale boundary is the same decision as BranchHealth's
    # stale_cutoff - keep the two in step
    def dated_sql
      ActiveRecord::Base.sanitize_sql_array(
        [ <<~SQL, stale_cutoff: cutoff(Config::REBASE_AFTER_DAYS), ancient_cutoff: cutoff(Config::ANCIENT_AFTER_DAYS) ]
          CASE
            WHEN patch_branches.base_committed_at IS NULL THEN 'unknown'
            WHEN patch_branches.base_committed_at >= :stale_cutoff THEN 'recent'
            WHEN patch_branches.base_committed_at >= :ancient_cutoff THEN 'stale'
            ELSE 'ancient'
          END
        SQL
      )
    end

    def cutoff(days)
      @repo_state.master_committed_at - days.days
    end
  end
end
