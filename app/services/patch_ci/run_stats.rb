module PatchCi
  # Every pipeline-panel aggregate, one query per public method. Takes resolved
  # values (a window, a date_trunc unit) and never params - see StatsParams.
  # Returns plain hashes and arrays; nothing here knows what a chart is.
  class RunStats
    # timeouts fold into their failure band: they would otherwise need a second
    # amber and a second red, and two near-identical hues in one stack is worse
    # than one band whose tooltip carries the split
    BAND_SQL = Arel.sql(<<~SQL.freeze)
      CASE patch_ci_runs.status
        WHEN 'success' THEN 'success'
        WHEN 'cancelled' THEN 'cancelled'
        WHEN 'tests_failed' THEN 'tests_failed'
        WHEN 'tests_timeout' THEN 'tests_failed'
        WHEN 'build_failed' THEN 'build_failed'
        WHEN 'build_timeout' THEN 'build_failed'
        ELSE 'infra_error'
      END
    SQL

    def initialize(since:, gran: "day", now: Time.current)
      @since = since
      @gran = gran
      @now = now
    end

    # one hash, so the controller caches one entry per param triple instead of
    # one per aggregate - and so a view cannot trigger a query mid-render
    def all
      { volume_by_status: volume_by_status, success_rate: success_rate, durations_by_era: durations_by_era,
        ccache_hit_rate: ccache_hit_rate, build_vs_ccache: build_vs_ccache,
        queue_latency: queue_latency, average_concurrency: average_concurrency,
        push_lag: push_lag, push_kind: push_kind,
        failure_concentration: failure_concentration, top_failing_tests: top_failing_tests,
        headline: headline, infra_health: infra_health, rerun_agreement: rerun_agreement }
    end

    # band names only, no stacking index: the stack order is a presentation
    # decision (it is what makes the CVD adjacency check pass), so it lives in
    # CiStatsHelper::STATUS_BANDS and a service does not reach into a helper
    def volume_by_status
      terminal_scope.group(bucket_sql, BAND_SQL).count
                    .map { |(bucket, band), count| { bucket: bucket, band: band, count: count } }
                    .sort_by { |row| [ row[:bucket], row[:band] ] }
    end

    # totals and wins in one pass (a FILTER, not two group().count round trips):
    # two queries under READ COMMITTED can straddle a run finishing between
    # them, so the live bucket's wins/total pair would come from different
    # snapshots and rate could read above 1.0
    def success_rate
      terminal_scope.group(bucket_sql)
                    .pluck(bucket_sql, Arel.sql("count(*)"),
                           Arel.sql("count(*) FILTER (WHERE patch_ci_runs.status = 'success')"))
                    .map { |bucket, total, wins| { bucket: bucket, total: total, rate: wins.to_f / total,
                                                   sparse: total < Config::SPARSE_BUCKET_RUNS } }
                    .sort_by { |row| row[:bucket] }
    end

    # grouped in SQL rather than in Ruby: a median of per-major medians is not
    # the family's median. Facets small multiples in the view, one per era.
    def durations_by_era
      success_scope
        .group(bucket_sql, era_sql)
        .pluck(bucket_sql, era_sql, *percentiles(:build_seconds), *percentiles(:test_seconds))
        .map do |bucket, era, build_p25, build_median, build_p75, test_p25, test_median, test_p75|
          { bucket: bucket, era: era,
            build_p25: build_p25, build_median: build_median, build_p75: build_p75,
            test_p25: test_p25, test_median: test_median, test_p75: test_p75 }
        end.sort_by { |row| [ row[:era], row[:bucket] ] }
    end

    def ccache_hit_rate
      select_rows(<<~SQL).map { |row| { bucket: row["bucket"], runs: row["runs"].to_i, rate: row["rate"].to_f } }
        SELECT bucket, count(*) AS runs,
               percentile_cont(0.5) WITHIN GROUP (ORDER BY hit::numeric / (hit + miss)) AS rate
        FROM (#{ccache_source}) t
        WHERE hit + miss > 0
        GROUP BY bucket
        ORDER BY bucket
      SQL
    end

    def build_vs_ccache
      select_rows(<<~SQL).map { |row| { build_seconds: row["build_seconds"].to_i, rate: row["rate"].to_f } }
        SELECT build_seconds, hit::numeric / (hit + miss) AS rate
        FROM (#{ccache_source}) t
        WHERE hit + miss > 0 AND build_seconds IS NOT NULL
      SQL
    end

    # two medians, both in seconds, on one axis: "GitHub picked it up slowly" and
    # "our push triggered nothing" are indistinguishable in a single elapsed number
    def queue_latency
      terminal_scope.joins(:patch_branch)
                    .group(bucket_sql)
                    .pluck(bucket_sql,
                           Arel.sql("percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch from (patch_ci_runs.started_at - patch_ci_runs.queued_at)))"),
                           Arel.sql("percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch from (patch_ci_runs.queued_at - patch_branches.pushed_at)))"))
                    .map { |bucket, start_median, queue_median| { bucket: bucket, start_median: start_median, queue_median: queue_median } }
                    .sort_by { |row| row[:bucket] }
    end

    # time-weighted, not a raw overlap count: an hourly bucket holds several
    # sequential ~11 minute runs, so counting "does this run touch the bucket"
    # reads ~6x actual concurrency - the exact inflation the overlap-count
    # version warned about but did not avoid. Sum each run's overlap seconds
    # with the bucket and divide by bucket width, so the number is directly
    # comparable to the slot budget.
    def average_concurrency
      from = @since || PatchCiRun.minimum(:queued_at)
      return [] if from.nil?

      sql = ActiveRecord::Base.sanitize_sql_array(
        [ <<~SQL, unit: @gran, from: from, to: @now, step: "1 #{@gran}", now: @now ]
          SELECT b.bucket,
                 COALESCE(SUM(extract(epoch from (
                   LEAST(COALESCE(r.completed_at, :now::timestamp), b.bucket + :step::interval)
                   - GREATEST(r.queued_at, b.bucket)
                 ))) FILTER (WHERE r.id IS NOT NULL), 0) / extract(epoch from :step::interval) AS concurrency
          FROM generate_series(date_trunc(:unit, :from::timestamp),
                               :to::timestamp,
                               :step::interval) AS b(bucket)
          LEFT JOIN patch_ci_runs r
            ON r.queued_at IS NOT NULL
           AND r.queued_at < b.bucket + :step::interval
           AND COALESCE(r.completed_at, :now::timestamp) >= b.bucket
          GROUP BY b.bucket
          ORDER BY b.bucket
        SQL
      )
      select_rows(sql).map { |row| { bucket: row["bucket"], concurrency: row["concurrency"].to_f } }
    end

    # replaces trigger_tier: measured, not guessed. band_index comes from
    # lag_bands so a run with no queued_at (or no message) still shows as
    # 'unknown' rather than being dropped by the join/group.
    def push_lag
      terminal_scope.joins(patch_branch: :message)
                    .group(bucket_sql, lag_band_sql)
                    .count
                    .map { |(bucket, band), count| { bucket: bucket, band: band, count: count, band_index: lag_bands.index(band) || lag_bands.size } }
                    .sort_by { |row| [ row[:bucket], row[:band_index] ] }
    end

    # window functions cannot be grouped in the same query, and classification
    # must see runs outside the window: a rebase whose first push predates the
    # range would otherwise read as a first push. So: classify over all terminal
    # runs first, filter to the window in the outer query.
    #
    # decision: the ordering only sees terminal runs (unbounded by the window,
    # but bounded by status). A queued/running run's sort key falls back through
    # started_at/queued_at/created_at, which can reorder relative to a later
    # completed_at once it finishes - so a run's kind could silently change on a
    # later page load for no reason of its own. Terminal-only keeps completed_at
    # as the one order key and makes a run's kind permanent once computed.
    def push_kind
      where = @since ? ActiveRecord::Base.sanitize_sql_array([ "AND t.completed_at >= ?", @since ]) : ""
      select_rows(<<~SQL).map { |row| { bucket: row["bucket"], kind: row["kind"], count: row["runs"].to_i } }
        SELECT #{bucket_sql("t")} AS bucket, t.kind, count(*) AS runs
        FROM (
          SELECT completed_at,
                 CASE
                   WHEN lag(id) OVER w IS NULL THEN 'first_push'
                   WHEN head_sha IS NOT NULL AND head_sha = lag(head_sha) OVER w THEN 'retry'
                   ELSE 'rebase'
                 END AS kind
          FROM (#{terminal_runs_unbounded.to_sql}) patch_ci_runs
          WINDOW w AS (
            PARTITION BY patch_branch_id
            ORDER BY completed_at, github_run_id, run_attempt
          )
        ) t
        WHERE t.completed_at IS NOT NULL #{where}
        GROUP BY 1, 2
        ORDER BY 1, 2
      SQL
    end

    TOP_LIST = 20

    # a run failing one suite is a patch bug; a run failing forty is usually one
    # crash cascading through everything that touched the same cluster afterwards
    def failure_concentration
      test_failure_scope
        .where("array_length(patch_ci_runs.failed_tests, 1) > 0")
        .group(Arel.sql("array_length(patch_ci_runs.failed_tests, 1)"))
        .count
        .map { |failures, runs| { failures: failures, runs: runs } }
        .sort_by { |row| row[:failures] }
    end

    # both figures matter: 85 failures across many branches is a flaky suite,
    # 85 across three is three broken patches
    # inner query built off terminal_scope, not off a hand-written predicate: a
    # second copy of PatchCiRun::TERMINAL_STATUSES in raw SQL is free to drift
    # from the model, and this way the scope stays the single owner
    def top_failing_tests
      inner = terminal_scope.select(Arel.sql("unnest(patch_ci_runs.failed_tests) AS name, patch_ci_runs.patch_branch_id")).to_sql
      select_rows(<<~SQL).map { |row| { name: row["name"], failures: row["failures"].to_i, branches: row["branches"].to_i } }
        SELECT name, count(*) AS failures, count(DISTINCT patch_branch_id) AS branches
        FROM (#{inner}) t
        GROUP BY name
        ORDER BY failures DESC, name ASC
        LIMIT #{TOP_LIST}
      SQL
    end

    # the tile row: one number per figure, denominator alongside so the view
    # can show a dash instead of a lying rate
    def headline
      totals = terminal_scope.group(:status).count
      runs = totals.values.sum
      build_median, test_median, queue_median = terminal_scope.pick(
        median_of("patch_ci_runs.build_seconds"),
        median_of("patch_ci_runs.test_seconds"),
        Arel.sql("percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch from (patch_ci_runs.started_at - patch_ci_runs.queued_at)))")
      )
      infra = totals.fetch("infra_error", 0)
      { runs: runs,
        successes: totals.fetch("success", 0),
        success_rate: rate(totals.fetch("success", 0), runs),
        build_median: build_median, test_median: test_median, queue_median: queue_median,
        infra: infra, infra_rate: rate(infra, runs),
        retries: terminal_scope.where("patch_ci_runs.run_attempt > 1").count }
    end

    # "is anything quietly broken" - every count here should read zero;
    # non-zero is worth a look, not a panic
    def infra_health
      { infra_error: terminal_scope.where(status: "infra_error").count,
        stuck: PatchCiRun.where(status: PatchCiRun::IN_FLIGHT_BRANCH_STATUSES)
                         .where(completed_at: nil)
                         .where("patch_ci_runs.queued_at < ?", @now - Config::STUCK_RUN_HOURS.hours)
                         .count,
        push_failed: PatchBranch.where(ci_status: "push_failed").count,
        ingest_error: terminal_scope.where("patch_ci_runs.payload ->> 'ingest_error' IS NOT NULL").count,
        no_payload: terminal_scope.where(payload: nil).count,
        # publish only gates on build_ok, so a built run with no image is a
        # publish that failed - not a patch that failed to compile. Neither
        # half of that can be read off the columns it looks like it can:
        # build_seconds is recorded for a failed build too, and image_ref is a
        # tag the publish job emits even when it never reached the push, so
        # only the digest proves an image exists.
        no_image: terminal_scope.where("patch_ci_runs.payload -> 'build' ->> 'ok' = 'true'")
                                .where(image_digest: nil).count }
    end

    # a retry is the same head twice: if the two verdicts disagree, CI is flaky
    # rather than the patch being borderline.
    # Inner query off terminal_scope rather than a hand-written predicate, so
    # PatchCiRun.terminal stays the only owner of the status list; the window is
    # inlined per OVER() instead of a named WINDOW clause, which select() cannot
    # express.
    #
    # same decision push_kind makes, for the same reason: a non-terminal run's
    # sort key falls back through started_at/queued_at/created_at and would
    # reorder relative to a later completed_at once it finishes, silently
    # flipping a verdict already computed - so the ordering only sees terminal
    # runs, same as push_kind. Unlike push_kind this is built off terminal_scope
    # (bounded by @since), not terminal_runs_unbounded: a pair straddling the
    # window edge undercounts by one pair rather than misclassifying, and the
    # denominator is already ~10 pairs total - not worth a second unbounded
    # query for that edge.
    def rerun_agreement
      window = "PARTITION BY patch_branch_id " \
               "ORDER BY COALESCE(completed_at, started_at, queued_at, created_at), " \
               "github_run_id, run_attempt"
      inner = terminal_scope.select(Arel.sql(<<~COLS)).to_sql
        patch_ci_runs.status,
        lag(patch_ci_runs.status) OVER (#{window}) AS prev_status,
        patch_ci_runs.head_sha,
        lag(patch_ci_runs.head_sha) OVER (#{window}) AS prev_sha
      COLS
      row = select_rows(<<~SQL).first
        SELECT count(*) AS pairs, count(*) FILTER (WHERE status <> prev_status) AS changed
        FROM (#{inner}) t
        WHERE prev_sha IS NOT NULL AND head_sha = prev_sha
      SQL
      { pairs: row["pairs"].to_i, changed: row["changed"].to_i }
    end

    private

    # single-value median, distinct shape from percentiles' p25/p50/p75 triple -
    # not worth a shared helper across the two, one column expression in
    # headline is not three
    def median_of(column)
      Arel.sql("percentile_cont(0.5) WITHIN GROUP (ORDER BY #{column})")
    end

    # nil, not zero: "0% infra errors" over no runs at all is a claim we cannot make
    def rate(part, total)
      return nil if total.to_i.zero?
      part.to_f / total
    end

    def test_failure_scope
      terminal_scope.where(status: %w[tests_failed tests_timeout])
    end

    # payload is hostile input: a non-numeric ccache value would take the whole
    # query down as a cast error, so the values are read as text, filtered by
    # regex, and only then cast. The regex guard lives in WHERE and the cast
    # lives in SELECT - safe because SQL evaluates FROM -> WHERE -> SELECT, so
    # the cast only ever sees rows the regex already passed. Do not "simplify"
    # by moving the cast into WHERE alongside the regex - Postgres does not
    # guarantee AND operands run left to right, so a cast there could still
    # fire on a row the regex was meant to reject. Same guard ci_ccache_line
    # applies for display.
    # digit count is bounded, not just character class: an all-digit value
    # with enough digits still overflows ::bigint and raises rather than
    # skipping the row - same failure mode the regex exists to prevent. 15
    # digits is far above any real ccache count and safely inside bigint range.
    # inner query is derived from success_scope itself, not a hand-copied
    # predicate, so PatchCiRun.terminal stays the one place the status list lives.
    # build_seconds is only used by build_vs_ccache, not ccache_hit_rate - one
    # shared source beats two near-identical queries, projecting one unused
    # column is the trade.
    def ccache_source
      success_scope
        .where("patch_ci_runs.payload #>> '{ccache,hit}' ~ '^[0-9]{1,15}$'")
        .where("patch_ci_runs.payload #>> '{ccache,miss}' ~ '^[0-9]{1,15}$'")
        .select(Arel.sql(<<~COLS)).to_sql
          #{bucket_sql} AS bucket,
          patch_ci_runs.build_seconds,
          (patch_ci_runs.payload #>> '{ccache,hit}')::bigint AS hit,
          (patch_ci_runs.payload #>> '{ccache,miss}')::bigint AS miss
        COLS
    end

    def select_rows(sql)
      ActiveRecord::Base.connection.select_all(sql).to_a
    end

    # percentile_cont ignores NULLs, which is what we want: a run with no
    # build_seconds is a run we know nothing about, not a zero-second build
    def percentiles(column)
      [ 0.25, 0.5, 0.75 ].map do |fraction|
        Arel.sql("percentile_cont(#{fraction}) WITHIN GROUP (ORDER BY patch_ci_runs.#{column})")
      end
    end

    # majors are integers from eras.yml, family names quoted through the
    # connection - never string-interpolated straight from Eras
    def era_sql
      @era_sql ||= begin
        whens = Eras.families.flat_map do |family|
          family.majors.map do |major|
            "WHEN #{major.to_i} THEN #{ActiveRecord::Base.connection.quote(family.name)}"
          end
        end
        Arel.sql("CASE patch_ci_runs.pg_major #{whens.join(' ')} ELSE 'unknown' END")
      end
    end

    def success_scope
      terminal_scope.where(status: "success")
    end

    # gran comes from StatsParams::GRANS, a whitelist - sanitized anyway, because
    # the next caller may not know that. table is parameterized so Task 9's
    # subquery alias can ask for its own bucket without string-surgering this
    # one; buckets come back as UTC (date_trunc runs in the DB's zone, and
    # completed_at is stored without a zone)
    def bucket_sql(table = "patch_ci_runs")
      Arel.sql(ActiveRecord::Base.sanitize_sql_array([ "date_trunc(?, #{table}.completed_at)", @gran ]))
    end

    def terminal_scope
      scope = PatchCiRun.terminal.where.not(completed_at: nil)
      @since ? scope.where(completed_at: @since..) : scope
    end

    # push_kind's source: terminal and completed, no window bound - classifying
    # a run must not depend on how much history the page happens to be showing
    def terminal_runs_unbounded
      PatchCiRun.where(status: PatchCiRun::TERMINAL_STATUSES).where.not(completed_at: nil)
    end

    def lag_bands
      @lag_bands ||= Config::PUSH_LAG_BUCKETS.map(&:first) + [ "unknown" ]
    end

    # < , not <=: a run queued exactly N days out belongs to the next band up,
    # same boundary rule BucketCase pins in its own spec
    def lag_band_sql
      @lag_band_sql ||= BucketCase.sql(
        Config::PUSH_LAG_BUCKETS,
        expr: "patch_ci_runs.queued_at",
        operator: "<",
        bound_sql: ->(days) { ActiveRecord::Base.sanitize_sql_array([ "messages.created_at + (? * interval '1 day')", days.to_i ]) },
        null_check: "patch_ci_runs.queued_at IS NULL OR messages.created_at IS NULL"
      )
    end
  end
end
