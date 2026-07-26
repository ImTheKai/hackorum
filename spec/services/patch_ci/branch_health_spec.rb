require "rails_helper"

RSpec.describe PatchCi::BranchHealth do
  let(:repo_state) { create(:patch_ci_repo_state, master_committed_at: Time.current) }
  let(:health) { described_class.new(repo_state: repo_state) }

  def active_time
    (PatchCi::Config::ACTIVE_THREAD_DAYS - 5).days.ago
  end

  def inactive_time
    (PatchCi::Config::ACTIVE_THREAD_DAYS + 5).days.ago
  end

  def stale_time
    repo_state.master_committed_at - (PatchCi::Config::REBASE_AFTER_DAYS + 5).days
  end

  def fresh_time
    repo_state.master_committed_at - 1.day
  end

  def branch(status: "applied", **attrs)
    has_last_message_at = attrs.key?(:last_message_at)
    last_message_at = attrs.delete(:last_message_at)
    topic = create(:topic)
    row = create(:patch_branch, topic: topic, status: status, **attrs)
    # the auto-created message's after_create callback bumps topic.last_message_at
    # to its own created_at; only override when the test cares about it
    topic.update_columns(last_message_at: last_message_at) if has_last_message_at
    row
  end

  def count_queries
    count = 0
    callback = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" }
    result = nil
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { result = yield }
    [ count, result ]
  end

  describe "bucket boundaries" do
    it "ci_status ci_none is wont_retry" do
      row = branch(ci_status: "ci_none", last_message_at: active_time)
      expect(health.bucket_for(row)).to eq("wont_retry")
    end

    it "topic with a committed commit is wont_retry" do
      row = branch(last_message_at: active_time)
      create(:commit_topic, topic: row.topic)
      expect(health.bucket_for(row)).to eq("wont_retry")
    end

    it "failed, apply stage, topic active is needs_rebase" do
      row = branch(status: "failed", failure_stage: "apply", last_message_at: active_time)
      expect(health.bucket_for(row)).to eq("needs_rebase")
    end

    it "failed, base_detection stage, topic active is needs_rebase" do
      row = branch(status: "failed", failure_stage: "base_detection", last_message_at: active_time)
      expect(health.bucket_for(row)).to eq("needs_rebase")
    end

    it "failed and topic inactive is never_applied" do
      row = branch(status: "failed", failure_stage: "apply", last_message_at: inactive_time)
      expect(health.bucket_for(row)).to eq("never_applied")
    end

    it "failed with a non-retryable failure_stage (extract) is never_applied even when topic is active" do
      row = branch(status: "failed", failure_stage: "extract", last_message_at: active_time)
      expect(health.bucket_for(row)).to eq("never_applied")
    end

    it "failed with a non-retryable failure_stage (error) is never_applied even when topic is active" do
      row = branch(status: "failed", failure_stage: "error", last_message_at: active_time)
      expect(health.bucket_for(row)).to eq("never_applied")
    end

    it "failed but topic has a committed commit is wont_retry (committed wins over failed)" do
      row = branch(status: "failed", failure_stage: "apply", last_message_at: inactive_time)
      create(:commit_topic, topic: row.topic)
      expect(health.bucket_for(row)).to eq("wont_retry")
    end

    it "failed, apply stage, active thread, but topic merged is never_applied (merged never reads needs_rebase)" do
      row = branch(status: "failed", failure_stage: "apply", last_message_at: active_time)
      row.topic.update_columns(merged_into_topic_id: create(:topic).id)
      expect(health.bucket_for(row)).to eq("never_applied")
    end

    it "applied but not pushed is awaiting_ci" do
      row = branch(pushed_at: nil, last_message_at: active_time)
      expect(health.bucket_for(row)).to eq("awaiting_ci")
    end

    it "pushed and running is awaiting_ci" do
      row = branch(pushed_at: Time.current, ci_status: "running",
                    base_committed_at: fresh_time, last_message_at: active_time)
      expect(health.bucket_for(row)).to eq("awaiting_ci")
    end

    it "pushed and pushed_awaiting_ci is awaiting_ci" do
      row = branch(pushed_at: Time.current, ci_status: "pushed_awaiting_ci",
                    base_committed_at: fresh_time, last_message_at: active_time)
      expect(health.bucket_for(row)).to eq("awaiting_ci")
      expect(health.scope_for("awaiting_ci").pluck(:id)).to include(row.id)
    end

    it "pushed with a master apply error and active topic is needs_rebase" do
      row = branch(pushed_at: Time.current, ci_status: "success",
                    base_committed_at: fresh_time, master_apply_error: "conflict in xlog.c",
                    last_message_at: active_time)
      expect(health.bucket_for(row)).to eq("needs_rebase")
    end

    it "pushed with a stale base and active topic is needs_rebase" do
      row = branch(pushed_at: Time.current, ci_status: "success",
                    base_committed_at: stale_time, last_message_at: active_time)
      expect(health.bucket_for(row)).to eq("needs_rebase")
    end

    it "pushed with nil base_committed_at and active topic is needs_rebase" do
      row = branch(pushed_at: Time.current, ci_status: "success",
                    base_committed_at: nil, last_message_at: active_time)
      expect(health.bucket_for(row)).to eq("needs_rebase")
    end

    it "pushed with a stale base and inactive topic is wont_retry" do
      row = branch(pushed_at: Time.current, ci_status: "success",
                    base_committed_at: stale_time, last_message_at: inactive_time)
      expect(health.bucket_for(row)).to eq("wont_retry")
    end

    it "pushed, stale base, active thread, but topic merged is wont_retry (merged never reads needs_rebase)" do
      row = branch(pushed_at: Time.current, ci_status: "success",
                    base_committed_at: stale_time, last_message_at: active_time)
      row.topic.update_columns(merged_into_topic_id: create(:topic).id)
      expect(health.bucket_for(row)).to eq("wont_retry")
    end

    it "pushed with a fresh base is fresh" do
      row = branch(pushed_at: Time.current, ci_status: "success",
                    base_committed_at: fresh_time, last_message_at: active_time)
      expect(health.bucket_for(row)).to eq("fresh")
    end
  end

  describe "#counts" do
    it "matches the exact bucket for each row in a mixed population" do
      branch(ci_status: "ci_none", last_message_at: active_time)
      branch(status: "failed", failure_stage: "apply", last_message_at: active_time)
      branch(status: "failed", failure_stage: "extract", last_message_at: active_time)
      branch(pushed_at: nil, last_message_at: active_time)
      branch(pushed_at: Time.current, ci_status: "queued",
             base_committed_at: fresh_time, last_message_at: active_time)
      branch(pushed_at: Time.current, ci_status: "success",
             base_committed_at: stale_time, last_message_at: active_time)
      branch(pushed_at: Time.current, ci_status: "success",
             base_committed_at: fresh_time, last_message_at: active_time)

      expect(health.counts).to eq(
        "fresh" => 1,
        "needs_rebase" => 2,
        "awaiting_ci" => 2,
        "wont_retry" => 1,
        "never_applied" => 1
      )
      expect(health.counts.values.sum).to eq(PatchBranch.current.count)
    end
  end

  describe "#scope_for" do
    it "returns the rows matching the bucket" do
      matching = branch(pushed_at: nil, last_message_at: active_time)
      branch(ci_status: "ci_none", last_message_at: active_time)

      expect(health.scope_for("awaiting_ci").pluck(:id)).to contain_exactly(matching.id)
    end

    it "accepts a symbol bucket name" do
      matching = branch(pushed_at: Time.current, ci_status: "success",
                         base_committed_at: fresh_time, last_message_at: active_time)

      expect(health.scope_for(:fresh).pluck(:id)).to include(matching.id)
    end

    it "raises ArgumentError with the bad value in the message for an unknown bucket" do
      expect { health.scope_for("bogus") }.to raise_error(ArgumentError, 'unknown bucket: "bogus"')
    end
  end

  describe "#filter" do
    it "accepts several buckets and joins topics itself" do
      not_pushed = branch(pushed_at: nil, last_message_at: active_time)
      skipped = branch(ci_status: "ci_none", last_message_at: active_time)
      branch(pushed_at: Time.current, ci_status: "success",
             base_committed_at: fresh_time, last_message_at: active_time)

      ids = health.filter(PatchBranch.current, [ "awaiting_ci", "wont_retry" ]).pluck(:id)

      expect(ids).to match_array([ not_pushed.id, skipped.id ])
    end

    it "returns the relation untouched for an empty list" do
      rows = [ branch(pushed_at: nil, last_message_at: active_time),
               branch(ci_status: "ci_none", last_message_at: active_time) ]

      expect(health.filter(PatchBranch.current, []).pluck(:id)).to match_array(rows.map(&:id))
    end

    # unlike scope_for, which raises: this one takes user input off a URL
    it "drops unknown bucket names instead of raising" do
      row = branch(pushed_at: nil, last_message_at: active_time)

      expect(health.filter(PatchBranch.current, [ "bogus" ]).pluck(:id)).to eq([ row.id ])
      expect(health.filter(PatchBranch.current, [ "awaiting_ci", "bogus" ]).pluck(:id)).to eq([ row.id ])
    end
  end

  describe "#bucket_for" do
    it "agrees with counts" do
      rows = [
        branch(ci_status: "ci_none", last_message_at: active_time),
        branch(status: "failed", failure_stage: "apply", last_message_at: inactive_time),
        branch(pushed_at: Time.current, ci_status: "success",
               base_committed_at: fresh_time, last_message_at: active_time)
      ]

      counts = health.counts
      tally = rows.group_by { |row| health.bucket_for(row) }.transform_values(&:count)
      expect(counts).to eq(described_class::BUCKETS.index_with { |b| tally.fetch(b, 0) })
    end
  end

  describe "#with_bucket" do
    it "adds a health_bucket column agreeing with bucket_for, in one query" do
      rows = [
        branch(ci_status: "ci_none", last_message_at: active_time),
        branch(status: "failed", failure_stage: "apply", last_message_at: active_time),
        branch(pushed_at: Time.current, ci_status: "success",
               base_committed_at: fresh_time, last_message_at: active_time)
      ]
      expected = rows.index_by(&:id).transform_values { |row| health.bucket_for(row) }

      queries, result = count_queries { health.with_bucket.where(id: rows.map(&:id)).to_a }

      expect(queries).to eq(1)
      result.each { |row| expect(row.health_bucket).to eq(expected[row.id]) }
    end
  end

  describe "#wont_retry_breakdown" do
    it "labels committed / ci_skip_reason / thread inactive, sorted desc" do
      2.times do
        row = branch(last_message_at: active_time)
        create(:commit_topic, topic: row.topic)
      end
      branch(ci_status: "ci_none", ci_skip_reason: "push failed: timeout", last_message_at: active_time)
      3.times do
        branch(pushed_at: Time.current, ci_status: "success",
               base_committed_at: stale_time, last_message_at: inactive_time)
      end

      breakdown = health.wont_retry_breakdown
      expect(breakdown).to eq(
        "thread inactive" => 3,
        "committed" => 2,
        "push failed: timeout" => 1
      )
      expect(breakdown.to_a).to eq(
        [ [ "thread inactive", 3 ], [ "committed", 2 ], [ "push failed: timeout", 1 ] ]
      )
    end

    it "falls back to the 'ci_none' label when ci_skip_reason is nil" do
      branch(ci_status: "ci_none", ci_skip_reason: nil, last_message_at: active_time)

      expect(health.wont_retry_breakdown).to eq("ci_none" => 1)
    end

    it "labels a row that is both ci_none and committed by ci_none (matches bucket_sql's own precedence)" do
      row = branch(ci_status: "ci_none", ci_skip_reason: "custom reason", last_message_at: active_time)
      create(:commit_topic, topic: row.topic)

      expect(health.wont_retry_breakdown).to eq("custom reason" => 1)
    end
  end

  describe "nil repo_state" do
    it "does not raise, using WORK_FROM as the stale cutoff" do
      health_no_repo = described_class.new(repo_state: nil)
      branch(pushed_at: Time.current, ci_status: "success",
             base_committed_at: 1.year.ago, last_message_at: active_time)

      expect { health_no_repo.counts }.not_to raise_error
    end

    it "classifies a pushed row with a normal past base as fresh under the WORK_FROM fallback" do
      health_no_repo = described_class.new(repo_state: nil)
      row = branch(pushed_at: Time.current, ci_status: "success",
                    base_committed_at: 3.days.ago, last_message_at: active_time)

      expect(health_no_repo.bucket_for(row)).to eq("fresh")
    end

    it "classifies a pushed nil-meta active row as needs_rebase under the WORK_FROM fallback" do
      health_no_repo = described_class.new(repo_state: nil)
      row = branch(pushed_at: Time.current, ci_status: "success",
                    base_committed_at: nil, last_message_at: active_time)

      expect(health_no_repo.bucket_for(row)).to eq("needs_rebase")
    end
  end
end
