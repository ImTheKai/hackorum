module PatchCi
  # A branch stuck without a verdict must surface as a result, not haunt the
  # in-progress list forever.
  class StuckRunMarker
    WAITING = PatchCiRun::IN_FLIGHT_BRANCH_STATUSES

    def call(now: Time.current)
      cutoff = now - Config::STUCK_RUN_HOURS.hours
      # bulk update: PatchBranch has validations and a required belongs_to,
      # one bad legacy row raising RecordInvalid must not kill the whole
      # orchestrator cycle. no callbacks on this model, so nothing is lost.
      # the branch's PatchCiRun row is left untouched on purpose - it stays
      # the honest record of what github actually reported.
      PatchBranch.where(ci_status: WAITING).where(pushed_at: ...cutoff)
                 .update_all(ci_status: "infra_error",
                             ci_skip_reason: "no CI verdict #{Config::STUCK_RUN_HOURS}h after push",
                             updated_at: now)
    end
  end
end
