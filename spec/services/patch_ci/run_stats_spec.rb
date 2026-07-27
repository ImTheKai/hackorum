require "rails_helper"

RSpec.describe PatchCi::RunStats do
  # a fixed instant, not Time.current arithmetic: bucket boundaries are the whole
  # point here and a spec that computes them the same way the code does proves
  # nothing
  let(:now) { Time.zone.parse("2026-07-20 12:00:00") }

  def run(completed_at: now - 1.hour, status: "success", **attrs)
    branch = attrs.delete(:patch_branch) || create(:patch_branch)
    create(:patch_ci_run, patch_branch: branch, status: status,
                          completed_at: completed_at, **attrs)
  end

  def stats(since: now - 7.days, gran: "day")
    described_class.new(since: since, gran: gran, now: now)
  end

  def volume_for(rows, band)
    rows.select { |row| row[:band] == band }.sum { |row| row[:count] }
  end

  describe "#volume_by_status" do
    it "counts one bucket per band" do
      run(status: "success")
      run(status: "success")
      run(status: "tests_failed")

      rows = stats.volume_by_status
      expect(volume_for(rows, "success")).to eq(2)
      expect(volume_for(rows, "tests_failed")).to eq(1)
    end

    it "folds tests_timeout into tests_failed and build_timeout into build_failed" do
      run(status: "tests_timeout")
      run(status: "build_timeout")

      rows = stats.volume_by_status
      expect(volume_for(rows, "tests_failed")).to eq(1)
      expect(volume_for(rows, "build_failed")).to eq(1)
      expect(rows.map { |row| row[:band] }).not_to include("tests_timeout", "build_timeout")
    end

    it "maps infra_error and cancelled to their own bands" do
      run(status: "infra_error")
      run(status: "cancelled")

      rows = stats.volume_by_status
      expect(volume_for(rows, "infra_error")).to eq(1)
      expect(volume_for(rows, "cancelled")).to eq(1)
    end

    it "excludes non-terminal runs" do
      run(status: "running", completed_at: nil)
      run(status: "queued", completed_at: nil)

      expect(stats.volume_by_status).to eq([])
    end

    # non-terminal statuses have no business carrying a completed_at, but
    # nothing stops one - this pins the .terminal half of the filter, not just
    # the completed_at half every other non-terminal example exercises
    it "excludes a non-terminal run that has a completed_at" do
      run(status: "running", completed_at: now - 1.hour)

      expect(stats.volume_by_status).to eq([])
    end

    it "excludes a run completed before the window" do
      run(completed_at: now - 8.days)

      expect(stats.volume_by_status).to eq([])
    end

    it "includes everything when since is nil" do
      run(completed_at: now - 400.days)

      expect(stats(since: nil).volume_by_status.sum { |row| row[:count] }).to eq(1)
    end

    it "buckets by day" do
      run(completed_at: Time.zone.parse("2026-07-19 23:59:59"))
      run(completed_at: Time.zone.parse("2026-07-20 00:00:01"))

      buckets = stats.volume_by_status.map { |row| row[:bucket] }.map(&:to_date).uniq.sort
      expect(buckets).to eq([ Date.new(2026, 7, 19), Date.new(2026, 7, 20) ])
    end

    it "buckets by hour" do
      run(completed_at: Time.zone.parse("2026-07-20 10:59:00"))
      run(completed_at: Time.zone.parse("2026-07-20 11:01:00"))

      buckets = stats(gran: "hour").volume_by_status.map { |row| row[:bucket] }.uniq.sort
      expect(buckets).to eq([ Time.zone.parse("2026-07-20 10:00:00"),
                              Time.zone.parse("2026-07-20 11:00:00") ])
    end

    it "buckets by week" do
      run(completed_at: Time.zone.parse("2026-07-19 12:00:00")) # Sunday
      run(completed_at: Time.zone.parse("2026-07-20 12:00:00")) # Monday

      buckets = stats(gran: "week", since: now - 30.days)
                .volume_by_status.map { |row| row[:bucket] }.uniq
      # asserting values, not just a count of 2: day buckets would also give two
      # distinct values here, so this pins the ISO Monday week start too
      expect(buckets.sort).to eq([ Time.zone.parse("2026-07-13"), Time.zone.parse("2026-07-20") ])
    end

    it "sorts by bucket then band name so the payload is stable between requests" do
      run(status: "tests_failed", completed_at: now - 2.hours)
      run(status: "success", completed_at: now - 2.hours)

      rows = stats.volume_by_status
      expect(rows.map { |row| row[:band] }).to eq(%w[success tests_failed])
    end

    # ci_stacked_bar_spec does colors.fetch(band) - a band BAND_SQL can produce
    # that STATUS_BANDS does not know is a KeyError, a 500 on /ci/stats
    it "maps every terminal status to a known band" do
      PatchCiRun::TERMINAL_STATUSES.each { |status| run(status: status) }

      expect(stats.volume_by_status.map { |row| row[:band] }.uniq - CiStatsHelper::STATUS_BANDS).to eq([])
    end
  end

  describe "#success_rate" do
    it "is success over terminal per bucket" do
      3.times { run(status: "success") }
      run(status: "tests_failed")

      row = stats.success_rate.first
      expect(row[:total]).to eq(4)
      expect(row[:rate]).to be_within(0.001).of(0.75)
    end

    it "returns no rows rather than a nil rate when the window is empty" do
      expect(stats.success_rate).to eq([])
    end

    it "flags a bucket below the sparse threshold" do
      (PatchCi::Config::SPARSE_BUCKET_RUNS - 1).times { run }

      expect(stats.success_rate.first[:sparse]).to be(true)
    end

    it "does not flag a bucket at the threshold" do
      PatchCi::Config::SPARSE_BUCKET_RUNS.times { run }

      expect(stats.success_rate.first[:sparse]).to be(false)
    end

    it "ignores non-terminal runs in the denominator" do
      run(status: "success")
      run(status: "running", completed_at: nil)

      expect(stats.success_rate.first[:rate]).to eq(1.0)
    end
  end

  describe "#durations_by_era" do
    it "groups by era family, not by major" do
      run(pg_major: 14, build_seconds: 100, test_seconds: 200)
      run(pg_major: 15, build_seconds: 200, test_seconds: 400)

      rows = stats.durations_by_era
      expect(rows.map { |row| row[:era] }.uniq).to eq([ "bullseye" ])
      # median of 100 and 200 across the family, not a median of two medians
      expect(rows.first[:build_median]).to be_within(0.1).of(150)
      expect(rows.first[:test_median]).to be_within(0.1).of(300)
    end

    it "reports p25 and p75" do
      [ 100, 200, 300, 400 ].each { |seconds| run(pg_major: 20, build_seconds: seconds) }

      row = stats.durations_by_era.first
      expect(row[:build_p25]).to be < row[:build_median]
      expect(row[:build_p75]).to be > row[:build_median]
    end

    it "keeps a major no family serves as unknown" do
      run(pg_major: 7, build_seconds: 100)

      expect(stats.durations_by_era.map { |row| row[:era] }).to eq([ "unknown" ])
    end

    it "keeps a null pg_major as unknown rather than dropping the run" do
      run(pg_major: nil, build_seconds: 100)

      expect(stats.durations_by_era.map { |row| row[:era] }).to eq([ "unknown" ])
    end

    it "ignores null durations instead of counting them as zero" do
      run(pg_major: 20, build_seconds: 100)
      run(pg_major: 20, build_seconds: nil)

      expect(stats.durations_by_era.first[:build_median]).to be_within(0.1).of(100)
    end

    it "excludes failed runs" do
      run(pg_major: 20, build_seconds: 100, status: "tests_failed")

      expect(stats.durations_by_era).to eq([])
    end
  end

  describe "ccache" do
    def ccache_run(hit:, miss:, **attrs)
      run(payload: { "ccache" => { "hit" => hit, "miss" => miss } }, **attrs)
    end

    it "computes the median hit rate per bucket" do
      ccache_run(hit: 1, miss: 9)   # 0.1
      ccache_run(hit: 3, miss: 7)   # 0.3

      expect(stats.ccache_hit_rate.first[:rate]).to be_within(0.001).of(0.2)
    end

    it "skips a run whose ccache value is not an integer, keeping the others" do
      ccache_run(hit: 1, miss: 1)
      ccache_run(hit: "lots", miss: 5)
      ccache_run(hit: { "nested" => 1 }, miss: 5)
      ccache_run(hit: -3, miss: 5)

      expect(stats.ccache_hit_rate.first[:runs]).to eq(1)
    end

    it "skips a run with no ccache key at all" do
      ccache_run(hit: 1, miss: 1)
      run(payload: { "ingest_error" => "boom" })

      expect(stats.ccache_hit_rate.first[:runs]).to eq(1)
    end

    it "skips a run with zero hits and zero misses instead of dividing by zero" do
      ccache_run(hit: 0, miss: 0)

      expect { stats.ccache_hit_rate }.not_to raise_error
      expect(stats.ccache_hit_rate).to eq([])
    end

    it "pairs build seconds with the hit rate for the scatter" do
      ccache_run(hit: 1, miss: 3, build_seconds: 120)

      point = stats.build_vs_ccache.first
      expect(point[:build_seconds]).to eq(120)
      expect(point[:rate]).to be_within(0.001).of(0.25)
    end

    it "leaves a run with no build_seconds out of the scatter" do
      ccache_run(hit: 1, miss: 3, build_seconds: nil)

      expect(stats.build_vs_ccache).to eq([])
    end

    # all-digit passes a character-class-only regex but still overflows
    # ::bigint - the exact failure mode the guard exists to prevent, pinned so
    # the regex cannot regress back to unbounded digits
    it "skips a run whose ccache value is all digits but too long to fit in bigint" do
      ccache_run(hit: 1, miss: 1)
      ccache_run(hit: ("9" * 28).to_i, miss: 5)

      expect(stats.ccache_hit_rate.first[:runs]).to eq(1)
    end
  end

  describe "#queue_latency" do
    it "reports the median wait from queued to started" do
      run(queued_at: now - 3.hours, started_at: now - 3.hours + 60.seconds)
      run(queued_at: now - 3.hours, started_at: now - 3.hours + 180.seconds)

      expect(stats.queue_latency.first[:start_median]).to be_within(0.1).of(120)
    end

    it "reports the median wait from push to queued" do
      branch = create(:patch_branch, pushed_at: now - 4.hours)
      run(patch_branch: branch, queued_at: now - 4.hours + 30.seconds)

      expect(stats.queue_latency.first[:queue_median]).to be_within(0.1).of(30)
    end

    it "leaves the push median nil when the branch was never pushed" do
      branch = create(:patch_branch, pushed_at: nil)
      run(patch_branch: branch, queued_at: now - 4.hours)

      expect(stats.queue_latency.first[:queue_median]).to be_nil
    end
  end

  describe "#average_concurrency" do
    it "gives a straddling run a fractional share of each bucket, not a full count in both" do
      # covers the second half of the 00:00 hour and the first quarter of the 01:00 hour
      run(queued_at: Time.zone.parse("2026-07-20 00:30:00"),
          completed_at: Time.zone.parse("2026-07-20 01:15:00"))

      rows = stats(gran: "hour").average_concurrency
      by_bucket = rows.index_by { |row| row[:bucket] }
      expect(by_bucket[Time.zone.parse("2026-07-20 00:00:00")][:concurrency]).to be_within(0.001).of(0.5)
      expect(by_bucket[Time.zone.parse("2026-07-20 01:00:00")][:concurrency]).to be_within(0.001).of(0.25)
    end

    it "contributes an unfinished run's concurrency from queued_at up to now" do
      create(:patch_ci_run, status: "running", queued_at: now - 90.minutes, completed_at: nil)

      rows = stats(gran: "hour", since: now - 3.hours).average_concurrency
      by_bucket = rows.index_by { |row| row[:bucket] }
      # queued at 10:30 with now at 12:00: half the 10:00 bucket, all of the 11:00 bucket
      expect(by_bucket[now - 2.hours][:concurrency]).to be_within(0.001).of(0.5)
      expect(by_bucket[now - 1.hour][:concurrency]).to be_within(0.001).of(1.0)
    end

    it "excludes a run with no queued_at rather than counting it from epoch" do
      run(queued_at: nil)

      expect(stats.average_concurrency.sum { |row| row[:concurrency] }).to eq(0)
    end

    it "reports zero concurrency, not nil, for a bucket with no overlapping runs" do
      run(queued_at: now - 3.hours, completed_at: now - 3.hours + 5.minutes)

      rows = stats(gran: "hour", since: now - 3.hours).average_concurrency
      expect(rows.map { |row| row[:concurrency] }).to include(0.0)
      expect(rows.map { |row| row[:concurrency] }).not_to include(nil)
    end
  end

  describe "#push_lag" do
    def run_with_message_age(seconds, **attrs)
      topic = create(:topic)
      message = create(:message, topic: topic, created_at: now - 5.days)
      branch = create(:patch_branch, topic: topic, message: message)
      run(patch_branch: branch, queued_at: message.created_at + seconds, **attrs)
    end

    it "puts a run queued 23h59m after posting in same day" do
      run_with_message_age(24.hours - 60.seconds)

      expect(stats.push_lag.map { |row| row[:band] }).to eq([ "same day" ])
    end

    it "puts a run queued exactly 24h after posting in days" do
      run_with_message_age(24.hours)

      expect(stats.push_lag.map { |row| row[:band] }).to eq([ "days" ])
    end

    it "puts a run queued 8 days after posting in weeks" do
      run_with_message_age(8.days)

      expect(stats.push_lag.map { |row| row[:band] }).to eq([ "weeks" ])
    end

    it "puts a run queued 2 years after posting in older" do
      run_with_message_age(730.days)

      expect(stats.push_lag.map { |row| row[:band] }).to eq([ "older" ])
    end

    it "puts a run with no queued_at in unknown" do
      run_with_message_age(1.hour, queued_at: nil)

      expect(stats.push_lag.map { |row| row[:band] }).to eq([ "unknown" ])
    end
  end

  describe "#push_kind" do
    def branch_runs(*head_shas, **attrs)
      branch = create(:patch_branch)
      head_shas.each_with_index do |sha, index|
        create(:patch_ci_run, patch_branch: branch, head_sha: sha,
                              status: "success", completed_at: now - (head_shas.size - index).hours,
                              **attrs)
      end
      branch
    end

    def kinds
      stats.push_kind.flat_map { |row| [ row[:kind] ] * row[:count] }
    end

    it "classifies a lone run as a first push" do
      branch_runs("aaa")

      expect(kinds).to eq([ "first_push" ])
    end

    it "classifies a later run with a new head_sha as a rebase" do
      branch_runs("aaa", "bbb")

      expect(kinds.tally).to eq("first_push" => 1, "rebase" => 1)
    end

    it "classifies a later run with the same head_sha as a retry" do
      branch_runs("aaa", "aaa")

      expect(kinds.tally).to eq("first_push" => 1, "retry" => 1)
    end

    it "classifies a second attempt on the same github run id as a retry" do
      branch = create(:patch_branch)
      create(:patch_ci_run, patch_branch: branch, github_run_id: 555, run_attempt: 1,
                            head_sha: "aaa", status: "success", completed_at: now - 2.hours)
      create(:patch_ci_run, patch_branch: branch, github_run_id: 555, run_attempt: 2,
                            head_sha: "aaa", status: "success", completed_at: now - 1.hour)

      expect(kinds.tally).to eq("first_push" => 1, "retry" => 1)
    end

    it "does not call a rebase a first push when the first push predates the window" do
      branch = create(:patch_branch)
      create(:patch_ci_run, patch_branch: branch, head_sha: "aaa", status: "success",
                            completed_at: now - 30.days)
      create(:patch_ci_run, patch_branch: branch, head_sha: "bbb", status: "success",
                            completed_at: now - 1.hour)

      expect(kinds).to eq([ "rebase" ])
    end

    # pins the "restrict the ordering to terminal runs" decision: an in-flight
    # run sitting between two terminal same-sha runs must not shift the second
    # one's previous-row lookup onto itself, or the same-sha pair reads as a
    # rebase instead of a retry. Fails if non-terminal runs join the ordering.
    it "ignores an in-flight run sitting between two same-sha terminal runs" do
      branch = create(:patch_branch)
      create(:patch_ci_run, patch_branch: branch, head_sha: "aaa", status: "success",
                            completed_at: now - 3.hours)
      create(:patch_ci_run, patch_branch: branch, head_sha: "bbb", status: "running",
                            completed_at: nil, queued_at: now - 2.hours)
      create(:patch_ci_run, patch_branch: branch, head_sha: "aaa", status: "success",
                            completed_at: now - 1.hour)

      expect(kinds.tally).to eq("first_push" => 1, "retry" => 1)
    end
  end

  describe "#failure_concentration" do
    it "buckets by how many suites a run failed" do
      run(status: "tests_failed", failed_tests: %w[a])
      run(status: "tests_failed", failed_tests: %w[a b c])

      expect(stats.failure_concentration).to include({ failures: 1, runs: 1 }, { failures: 3, runs: 1 })
    end

    it "excludes a failing run with an empty failure list" do
      run(status: "tests_failed", failed_tests: [])

      expect(stats.failure_concentration).to eq([])
    end

    it "excludes successful runs" do
      run(status: "success", failed_tests: %w[a])

      expect(stats.failure_concentration).to eq([])
    end
  end

  describe "#top_failing_tests" do
    it "counts total failures and distinct branches" do
      first = create(:patch_branch)
      second = create(:patch_branch)
      run(patch_branch: first, status: "tests_failed", failed_tests: %w[regress/psql])
      run(patch_branch: first, status: "tests_failed", failed_tests: %w[regress/psql])
      run(patch_branch: second, status: "tests_failed", failed_tests: %w[regress/psql])

      row = stats.top_failing_tests.first
      expect(row[:name]).to eq("regress/psql")
      expect(row[:failures]).to eq(3)
      expect(row[:branches]).to eq(2)
    end

    it "counts a duplicate inside one run twice in the total and once in branches" do
      branch = create(:patch_branch)
      run(patch_branch: branch, status: "tests_failed", failed_tests: %w[regress/psql regress/psql])

      row = stats.top_failing_tests.first
      expect(row[:failures]).to eq(2)
      expect(row[:branches]).to eq(1)
    end

    it "orders by failures desc then name asc" do
      run(status: "tests_failed", failed_tests: %w[bbb bbb aaa])
      run(status: "tests_failed", failed_tests: %w[ccc])

      expect(stats.top_failing_tests.map { |row| row[:name] }).to eq(%w[bbb aaa ccc])
    end

    it "caps at 20 rows" do
      run(status: "tests_failed", failed_tests: (1..30).map { |n| "suite#{n}" })

      expect(stats.top_failing_tests.size).to eq(20)
    end
  end

  describe "#headline" do
    it "reports counts and medians" do
      run(status: "success", build_seconds: 100, test_seconds: 200,
          queued_at: now - 2.hours, started_at: now - 2.hours + 30.seconds)
      run(status: "tests_failed", build_seconds: 300, test_seconds: 400)

      headline = stats.headline
      expect(headline[:runs]).to eq(2)
      expect(headline[:success_rate]).to be_within(0.001).of(0.5)
      expect(headline[:build_median]).to be_within(0.1).of(200)
      expect(headline[:test_median]).to be_within(0.1).of(300)
    end

    it "returns nil rates rather than zero when there are no runs" do
      headline = stats.headline
      expect(headline[:runs]).to eq(0)
      expect(headline[:success_rate]).to be_nil
      expect(headline[:infra_rate]).to be_nil
    end

    it "counts retries" do
      branch = create(:patch_branch)
      create(:patch_ci_run, patch_branch: branch, github_run_id: 77, run_attempt: 2,
                            status: "success", completed_at: now - 1.hour)

      expect(stats.headline[:retries]).to eq(1)
    end
  end

  describe "#infra_health" do
    it "counts infra errors" do
      run(status: "infra_error")

      expect(stats.infra_health[:infra_error]).to eq(1)
    end

    it "counts runs stuck in flight past the threshold" do
      create(:patch_ci_run, status: "running", completed_at: nil,
                            queued_at: now - (PatchCi::Config::STUCK_RUN_HOURS + 1).hours)

      expect(stats.infra_health[:stuck]).to eq(1)
    end

    # the ref is a tag the publish job emits whether or not it got as far as
    # pushing, so only the digest says an image exists
    it "counts a build that pushed no digest" do
      run(status: "success", build_seconds: 120, payload: { "build" => { "ok" => true } },
          image_ref: "ghcr.io/x/postgres-patch:t1", image_digest: nil)

      expect(stats.infra_health[:no_image]).to eq(1)
    end

    it "does not count a build whose publish recorded a digest" do
      run(status: "success", build_seconds: 120, payload: { "build" => { "ok" => true } },
          image_ref: "ghcr.io/x/postgres-patch:t1", image_digest: "sha256:abc")

      expect(stats.infra_health[:no_image]).to eq(0)
    end

    # a failed build records its seconds like any other - reading those as
    # "it built" counts every compile failure as a broken publish
    it "does not count a build failure that recorded seconds" do
      run(status: "build_failed", build_seconds: 300, payload: { "build" => { "ok" => false } },
          image_ref: nil, image_digest: nil)

      expect(stats.infra_health[:no_image]).to eq(0)
    end

    it "counts a payload carrying an ingest_error" do
      run(payload: { "ingest_error" => "unparsable" })

      expect(stats.infra_health[:ingest_error]).to eq(1)
    end

    it "counts a run with no payload" do
      run(payload: nil)

      expect(stats.infra_health[:no_payload]).to eq(1)
    end
  end

  describe "#rerun_agreement" do
    it "counts a retry that changed verdict" do
      branch = create(:patch_branch)
      create(:patch_ci_run, patch_branch: branch, head_sha: "aaa", status: "tests_failed",
                            completed_at: now - 2.hours)
      create(:patch_ci_run, patch_branch: branch, head_sha: "aaa", status: "success",
                            completed_at: now - 1.hour)

      expect(stats.rerun_agreement).to eq(pairs: 1, changed: 1)
    end

    it "counts a retry that agreed" do
      branch = create(:patch_branch)
      2.times do |i|
        create(:patch_ci_run, patch_branch: branch, head_sha: "aaa", status: "success",
                              completed_at: now - (2 - i).hours)
      end

      expect(stats.rerun_agreement).to eq(pairs: 1, changed: 0)
    end

    it "ignores a re-push on a new head_sha" do
      branch = create(:patch_branch)
      create(:patch_ci_run, patch_branch: branch, head_sha: "aaa", status: "success",
                            completed_at: now - 2.hours)
      create(:patch_ci_run, patch_branch: branch, head_sha: "bbb", status: "tests_failed",
                            completed_at: now - 1.hour)

      expect(stats.rerun_agreement).to eq(pairs: 0, changed: 0)
    end
  end
end
