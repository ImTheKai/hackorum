module PatchCi
  class Ingestor
    LIFECYCLE = {
      "queued" => "queued", "requested" => "queued", "waiting" => "queued",
      "pending" => "queued", "in_progress" => "running"
    }.freeze

    # payloads: { run_id => raw result.json string }
    def initialize(payloads: {})
      @payloads = payloads
    end

    def ingest(runs)
      # ascending id/attempt is only a recency proxy, not a guarantee: it is
      # sound here because at most one run id is ever current for a given
      # head_sha (single push trigger, unchanged-sha push is a no-op ref
      # update). actual correctness comes from the head_sha gate in promote.
      # a second trigger (e.g. workflow_dispatch) sharing the same head_sha
      # across two run ids would break this silently.
      runs.sort_by { |run| [ run.id.to_i, run.attempt.to_i ] }.each do |run|
        branch = PatchBranch.find_by(branch_name: run.branch)
        next unless branch

        record = upsert(branch, run)
        promote(branch, record, run)
      end
    end

    private

    def upsert(branch, run)
      record = PatchCiRun.find_or_initialize_by(github_run_id: run.id, run_attempt: run.attempt)
      payload = payload_for(run)
      accepted = payload&.valid? && payload.run_id == run.id

      # we already learned this run's verdict; a later failure to re-read its
      # payload says nothing about the run, so do not overwrite what we know.
      # (a run with an accepted payload is already terminal, so lifecycle
      # fields below are not worth refreshing either)
      return record if !accepted && already_recorded?(record)

      record.assign_attributes(
        patch_branch_id: branch.id,
        head_sha: run.head_sha,
        conclusion: run.conclusion,
        status: status_for(run, accepted, payload),
        queued_at: run.queued_at,
        started_at: run.started_at,
        completed_at: run.completed_at
      )

      if accepted
        record.assign_attributes(
          pg_major: payload.pg_major,
          build_seconds: payload.build_seconds,
          test_seconds: payload.test_seconds,
          failed_tests: payload.failed_tests,
          image_ref: payload.image_ref.presence,
          image_digest: payload.image_digest.presence,
          payload: payload.raw
        )
      elsif payload
        # payload arrived but did not survive validation; keep the reason,
        # otherwise infra_error is indistinguishable from no payload at all
        record.payload = { "ingest_error" => payload_error(payload, run) }
      end

      record.save!
      record
    end

    def already_recorded?(record)
      record.persisted? && record.payload.present? && !record.payload.key?("ingest_error")
    end

    def payload_for(run)
      raw = @payloads[run.id]
      raw ? ResultPayload.parse(raw) : nil
    end

    def payload_error(payload, run)
      return payload.error unless payload.valid?
      "run_id mismatch: payload says #{payload.run_id}, run is #{run.id}"
    end

    def status_for(run, accepted, payload)
      return LIFECYCLE.fetch(run.status, "running") unless run.completed?
      return "cancelled" if run.conclusion == "cancelled"
      # never infer success from absence: no payload means we do not know
      return "infra_error" unless accepted
      payload.status
    end

    # a run for an older push must not overwrite the current verdict
    def promote(branch, record, run)
      return unless branch.pushed_head_sha.present?
      return unless run.head_sha == branch.pushed_head_sha

      branch.update!(latest_ci_run_id: record.id, ci_status: record.status)
    end
  end
end
