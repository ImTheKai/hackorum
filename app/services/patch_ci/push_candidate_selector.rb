module PatchCi
  class PushCandidateSelector
    attr_reader :rejections

    def initialize(repo, force: false, limit: nil)
      @repo = repo
      @force = force
      @limit = limit
      @detector = EraDetector.new(repo)
      @rejections = {}
    end

    # PatchBranch rows that are actually safe to push, with @rejections filled
    # in for the ones that are not. Rows past @limit get neither: deferred to
    # next cycle, not rejected, no ci_skip_reason should be written for them.
    def eligible
      @rejections = {}
      rows = latest_per_topic
      rows = rows.reject { |row| row.pushed_at.present? } unless @force
      rows = rows.select { |row| keep?(row) }
      @limit ? rows.first(@limit) : rows
    end

    private

    def latest_per_topic
      PatchBranch
        .applied
        .joins(:message)
        .select("DISTINCT ON (patch_branches.topic_id) patch_branches.*")
        .order("patch_branches.topic_id, messages.created_at DESC, messages.id DESC")
        .to_a
    end

    def keep?(row)
      # the DB row is not evidence the branch exists
      head = @repo.rev_parse(row.branch_name)
      return reject(row, "branch missing from repo") unless head
      return reject(row, "base sha missing") if row.base_sha.blank?
      return reject(row, "branch has no commits beyond base") if head == @repo.rev_parse(row.base_sha)

      changed = changed_paths(row.base_sha, head)
      # a control that cannot verify must refuse, not wave through
      return reject(row, "cannot inspect changed paths") if changed.nil?
      return reject(row, "patchset touches .github/") if changed.any? { |p| p.start_with?(".github/") }

      major = @detector.major_for(row.base_sha)
      return reject(row, "cannot determine pg major of base") unless major
      return reject(row, "no era image for pg#{major}") unless @detector.supported?(major)

      true
    end

    def changed_paths(base, head)
      result = @repo.run("diff", "--name-only", "#{base}..#{head}")
      return nil unless result.success?
      result.stdout.split("\n")
    end

    def reject(row, reason)
      @rejections[row.id] = reason
      false
    end
  end
end
