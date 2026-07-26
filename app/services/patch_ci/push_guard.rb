module PatchCi
  # The last line of defense before a push. Refuses when it cannot verify.
  class PushGuard
    def initialize(repo)
      @repo = repo
      @detector = EraDetector.new(repo)
    end

    # nil = safe to push; otherwise the human-readable refusal
    def check(row)
      # free row-state checks first: the planner should never emit these, but
      # this is the last line of defense and must not trust the planner
      return "row not applied" unless row.status == "applied"
      return "row superseded" if row.superseded_by_id.present?

      # the DB row is not evidence the branch exists
      head = @repo.rev_parse(row.branch_name)
      return "branch missing from repo" unless head
      return "base sha missing" if row.base_sha.blank?
      return "branch has no commits beyond base" if head == @repo.rev_parse(row.base_sha)

      changed = changed_paths(row.base_sha, head)
      return "cannot inspect changed paths" if changed.nil?
      return "patchset touches .github/" if changed.any? { |p| p.start_with?(".github/") }

      major = @detector.major_for(row.base_sha)
      return "cannot determine pg major of base" unless major
      return "no era image for pg#{major}" unless @detector.supported?(major)

      nil
    end

    private

    def changed_paths(base, head)
      result = @repo.run("diff", "--name-only", "#{base}..#{head}")
      return nil unless result.success?
      result.stdout.split("\n")
    end
  end
end
