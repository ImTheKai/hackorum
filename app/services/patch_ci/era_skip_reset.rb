module PatchCi
  # "no era image for pgN" is a temporary condition recorded as a permanent
  # verdict. ci_none reads as wont_retry in BranchHealth and no Planner tier
  # revisits it - backfill takes ci_status IS NULL or push_failed, rebase needs
  # pushed_at or a failed apply, new_version only takes messages with no row at
  # all - so a row skipped before its era image existed stays stranded after the
  # image lands. Clearing the skip puts it back at ci_status IS NULL, which the
  # backfill tier picks up.
  #
  # Runs every cycle rather than as a one-off migration: the next family added
  # starts life as a disabled stub too, and nobody should have to remember this.
  class EraSkipReset
    def call
      reasons = supported_reasons
      return 0 if reasons.empty?

      PatchBranch.where(ci_status: "ci_none", ci_skip_reason: reasons)
                 .update_all(ci_status: nil, ci_skip_reason: nil, updated_at: Time.current)
    end

    private

    # exact reasons for enabled majors only, never a LIKE over every era skip.
    # A major with no image yet has to keep its skip: clearing it would strand
    # the row in a clear -> plan -> guard rejects -> skip -> clear loop, burning
    # a planner slot every cycle on work that cannot succeed.
    def supported_reasons
      Eras.families.select(&:enabled).flat_map(&:majors)
          .map { |major| PushGuard.no_era_image_reason(major) }
    end
  end
end
