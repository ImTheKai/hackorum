module PatchCi
  # The single source of table-ready branch rows. Every consumer of the
  # unified table - the branches page, the dashboard sections - goes through
  # here, so they cannot drift into showing different things.
  class BranchRows
    def initialize(repo_state:,
                   health: BranchHealth.new(repo_state: repo_state),
                   freshness: BaseFreshness.new(repo_state: repo_state),
                   check: MasterCheck.new(repo_state: repo_state))
      @health = health
      @freshness = freshness
      @check = check
    end

    attr_reader :health, :freshness, :check

    # relation -> the same relation, loaded, decorated and with run summaries
    # on its records. Still a relation, so kaminari can paginate the object
    # the table renders.
    def load(relation)
      attach_runs(decorate(relation).includes(:topic).load)
    end

    private

    # relation -> relation, with health_bucket, base_tier and check_tier
    # selected. All three also select the star for their standalone callers,
    # see BaseFreshness#with_tier - select_values is a union, so composing them
    # still asks for it once.
    def decorate(relation)
      @check.with_tier(@freshness.with_tier(@health.with_bucket(relation)))
    end

    # mutates the rows it is handed. Every row gets a summary or an explicit
    # nil - an unset one raises, so a skipped row cannot render as "no result".
    def attach_runs(rows)
      ids = rows.filter_map(&:latest_ci_run_id)
      by_id = ids.empty? ? {} : run_summaries(ids)
      rows.each { |row| row.latest_run_summary = by_id[row.latest_ci_run_id] }
      rows
    end

    # list_columns drops payload: up to 256KB of github json per row
    def run_summaries(ids)
      PatchCiRun.where(id: ids).select(*PatchCiRun.list_columns).readonly.index_by(&:id)
    end
  end
end
