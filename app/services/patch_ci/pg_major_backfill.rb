module PatchCi
  # One-off fill for rows created before patch_branches carried pg_major.
  # Re-runnable: only touches rows where it is still NULL, so a later apply
  # that failed detection gets another chance on the next run.
  class PgMajorBackfill
    def initialize(detector:, io: $stdout)
      @detector = detector
      @io = io
    end

    def call
      from_runs
      from_detector
    end

    private

    # what the CI reported for a real run beats anything we can re-derive - the
    # same major either way, since CI builds the base commit's own era
    def from_runs
      count = PatchBranch.connection.update(<<~SQL)
        UPDATE patch_branches
           SET pg_major = patch_ci_runs.pg_major
          FROM patch_ci_runs
         WHERE patch_ci_runs.id = patch_branches.latest_ci_run_id
           AND patch_ci_runs.patch_branch_id = patch_branches.id
           AND patch_branches.pg_major IS NULL
           AND patch_ci_runs.pg_major IS NOT NULL
      SQL
      @io.puts("filled #{count} rows from runs")
    end

    def from_detector
      scope = PatchBranch.where(pg_major: nil).where.not(base_sha: nil)
      total = scope.count
      done = 0
      wrote = 0
      scope.find_each do |row|
        major = @detector.major_for(row.base_sha)
        if major
          # update_columns: this is bookkeeping, and updated_at is the table's
          # default sort key
          row.update_columns(pg_major: major)
          wrote += 1
        else
          @io.puts("no major for #{row.branch_name} base #{row.base_sha}")
        end
        done += 1
        @io.puts("[#{done}/#{total}]") if (done % 500).zero?
      end
      @io.puts("detector pass done, wrote #{wrote}/#{done}")
    end
  end
end
