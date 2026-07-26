module PatchCi
  # refs/hackorum-ci/* grows forever otherwise; drop what is safely ingested
  # and old enough that nobody needs to re-read it.
  class ResultRefPruner
    DEFAULT_LIMIT = 100

    def initialize(repo, remote: "origin")
      @repo = repo
      @remote = remote
    end

    # lists refs itself: a filtered view would hide prunable refs forever
    def prune!(limit: DEFAULT_LIMIT)
      listing = @repo.run("for-each-ref", "--format=%(refname)", ResultRefs::NAMESPACE)
      return 0 unless listing.success?

      by_run_id = listing.stdout.split("\n").index_by { |ref| ResultRefs.run_id_for(ref) }
      by_run_id.delete(0)
      return 0 if by_run_id.empty?

      ids = prunable_ids(by_run_id.keys, limit)
      return 0 if ids.empty?

      refs = ids.map { |id| by_run_id[id] }
      # refspecs stay fully qualified: a short name hard-errors when the remote
      # ref is already gone, a qualified one only warns and exits 0
      return 0 unless @repo.run("push", @remote, *refs.map { |ref| ":#{ref}" }).success?

      # a local left behind after the remote delete is not a correctness
      # problem: fetch! --prune drops it on the next cycle
      deletes = refs.map { |ref| "delete #{ref}\n" }.join
      return 0 unless @repo.run("update-ref", "--stdin", stdin: deletes).success?

      refs.size
    end

    private

    def prunable_ids(run_ids, limit)
      PatchCiRun.terminal.where.not(payload: nil)
                # an ingest_error marker means the payload never made it into
                # the row, so the ref is still the only copy
                .where("NOT (payload ? 'ingest_error')")
                # a re-run from the UI reuses the ref; deleting it while a
                # later attempt is still live would record infra_error for it
                .where("NOT EXISTS (SELECT 1 FROM patch_ci_runs live" \
                       " WHERE live.github_run_id = patch_ci_runs.github_run_id" \
                       " AND live.status NOT IN (?))", PatchCiRun::TERMINAL_STATUSES)
                .where(github_run_id: run_ids)
                .where("completed_at < ?", Config::RESULT_REF_KEEP_DAYS.days.ago)
                .limit(limit).pluck(:github_run_id)
    end
  end
end
