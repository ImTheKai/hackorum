require "digest"
require "tmpdir"

module PatchBranches
  # One message end to end: extract, try master, detect base, apply, save.
  # The single writer of patch_branches rows (Runner fans out over this).
  class ApplyOne
    PROBE_PREFIX = "rebase_probe_".freeze

    # exposed for callers that need the partial context of a failed call
    # (Runner turns it into an "error" row + counters)
    attr_reader :record, :message, :save_error

    def initialize(repo:, worktree:, force: false)
      @repo = repo
      @worktree = worktree
      @force = force
      @era = PatchCi::EraDetector.new(repo)
    end

    # -> [ outcome_symbol, PatchBranch or nil ]
    #
    # master_only probes master and nothing else: on success the row and the
    # branch move to the new master, on any failure only the master-attempt
    # columns are touched, so a probe can never damage a working branch or
    # hide its row from the planner.
    def call(message_id, master_sha:, master_only: false)
      reset_state
      @master_only = master_only
      @message = Message.includes(:attachments, :topic).find(message_id)
      @branch_name = "t#{@message.topic_id}_#{@message.topic.chronological_index_of(@message)}"
      @record = PatchBranch.find_or_initialize_by(message_id: @message.id)

      if master_only
        # no row means no branch to rebase; building one is the normal path's
        # job, and a probe must never write a first version of a row
        return [ :skipped, @record ] unless @record.persisted?
        # already sitting on this master: re-applying would only churn the ref
        if @record.status == "applied" && @record.base_sha == master_sha
          return [ :already_current, @record ]
        end
      end

      Dir.mktmpdir("patchset") do |dir|
        files = PatchsetExtractor.new(@message).extract(dir)
        content_hash = Digest::SHA256.hexdigest(files.map { |f| File.binread(f) }.join)

        # a master probe is an explicit "try it again now", and its input
        # always looks skippable (applied row, unchanged patchset)
        return [ :skipped, @record ] if !master_only && skippable?(content_hash)

        applier = Applier.new(@worktree)
        return apply_master_only(applier, files, master_sha, content_hash) if master_only

        apply_with_base_detection(applier, files, master_sha, content_hash)
      end
    rescue PatchsetExtractor::Error => e
      save_failure(failure_stage: "extract", failure_reason: e.message)
      [ :extract_failed, @record ]
    end

    # Writes the "error" row for an exception raised out of #call (a probe only
    # gets its master-attempt columns touched). Returns the exception the save
    # itself died with, nil when the row was written.
    def persist_error(e)
      return nil unless @record && @message && @branch_name

      save_failure(failure_stage: "error",
                   failure_reason: clip("#{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"))
      @save_error
    end

    private

    def reset_state
      @message = nil
      @branch_name = nil
      @record = nil
      @save_error = nil
      @master_only = false
    end

    def apply_with_base_detection(applier, files, master_sha, content_hash)
      master_result = applier.apply(master_sha, files, @branch_name,
                                    committed_at: @message.created_at)
      if master_result.success?
        save(status: "applied", base_sha: master_sha, on_master: true,
             base_source: "master", content_hash: content_hash, master_apply_error: nil)
        return [ :applied_on_master, @record ]
      end

      detection = BaseCommitDetector
        .new(@repo, files, submission_date: @message.created_at)
        .detect

      if detection.nil?
        save(status: "failed", failure_stage: "base_detection",
             failure_reason: clip(master_result.output),
             conflict_files: master_result.conflict_files,
             content_hash: content_hash, master_apply_error: clip(master_result.output))
        return [ :no_base, @record ]
      end

      result = detection.sha == master_sha ? master_result
                                           : applier.apply(detection.sha, files, @branch_name,
                                                           committed_at: @message.created_at)

      if result.success?
        save(status: "applied", base_sha: detection.sha, on_master: false,
             base_source: detection.source, content_hash: content_hash,
             master_apply_error: clip(master_result.output))
        [ :applied_on_base, @record ]
      else
        save(status: "failed", failure_stage: "apply", base_sha: detection.sha,
             base_source: detection.source, failure_reason: clip(result.output),
             conflict_files: result.conflict_files,
             content_hash: content_hash, master_apply_error: clip(master_result.output))
        [ :apply_failed, @record ]
      end
    end

    # Applier deletes the branch it was handed when an apply fails, so the
    # probe gets a scratch name and the real branch only moves on success.
    def apply_master_only(applier, files, master_sha, content_hash)
      probe = "#{PROBE_PREFIX}#{@branch_name}"
      result = applier.apply(master_sha, files, probe, committed_at: @message.created_at)

      unless result.success?
        # no attempted_at bump on purpose: the row's own base was not retried,
        # only master was, and that has its own timestamp
        touch_master_apply_only(clip(result.output))
        return [ :master_apply_failed, @record ]
      end

      # branch first, row second - not atomic. A crash in between leaves a
      # branch ahead of a stale row; last_master_apply_at is still old, so the
      # next probe picks the row up again and repairs both.
      @worktree.run!("branch", "-f", @branch_name, probe)
      @worktree.run("branch", "-D", probe)
      save(status: "applied", base_sha: master_sha, on_master: true,
           base_source: "master", content_hash: content_hash, master_apply_error: nil)
      [ :applied_on_master, @record ]
    end

    def skippable?(content_hash)
      !@force && @record.persisted? &&
        @record.status == "applied" && @record.patch_content_hash == content_hash &&
        @record.base_committed_at.present?
    end

    # A probe never writes status/failure_*: those move the row out of every
    # planner tier, so a failed probe would retire a healthy pushed branch.
    # master_apply_error is the one column that keeps it in the rebase tier.
    def save_failure(failure_stage:, failure_reason:)
      return touch_master_apply_only(clip(failure_reason)) if @master_only

      tolerantly do
        save(status: "failed", failure_stage: failure_stage, failure_reason: failure_reason)
      end
    end

    def touch_master_apply_only(error)
      tolerantly do
        touch_master_apply(error)
        @record.save!
      end
    end

    # a save on a rescue path (e.g. branch_name unique collision, or a row that
    # never made it to valid) must not kill the caller; the exception is
    # reported through save_error instead
    def tolerantly
      yield
      nil
    rescue => e
      @save_error = e
    end

    def save(status:, base_sha: nil, on_master: false, base_source: nil,
             failure_stage: nil, failure_reason: nil, conflict_files: [],
             content_hash: nil, master_apply_error: :unset)
      now = Time.current
      committed_at = base_sha && @repo.commit_time(base_sha)
      Rails.logger.warn("patch_branches meta lookup failed for #{@branch_name} base #{base_sha}") if base_sha && !committed_at
      @record.assign_attributes(
        topic_id: @message.topic_id,
        branch_name: @branch_name,
        status: status,
        base_sha: base_sha,
        on_master: on_master,
        base_source: base_source,
        failure_stage: failure_stage,
        failure_reason: failure_reason,
        conflict_files: conflict_files || [],
        patch_content_hash: content_hash,
        attempted_at: now,
        base_committed_at: committed_at,
        base_commit_height: base_sha && @repo.commit_height(base_sha),
        # the major the base commit itself belongs to, not the newest one that
        # could build the patch. PgMajorBackfill reads the same number back off
        # patch_ci_runs, which agrees only because CI builds the base's own era.
        pg_major: base_sha && @era.major_for(base_sha)
      )
      touch_master_apply(master_apply_error, now: now) unless master_apply_error == :unset
      @record.save!
    end

    def touch_master_apply(error, now: Time.current)
      @record.assign_attributes(last_master_apply_at: now, master_apply_error: error)
    end

    def clip(text)
      text.to_s.scrub("?").slice(0, 20_000)
    end
  end
end
