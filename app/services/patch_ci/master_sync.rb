module PatchCi
  # Two remotes, two jobs. Upstream is where master comes from; the fork only
  # mirrors it. Kept out of Orchestrator because a mirror push is not part of
  # the pipeline: it can fail forever on a remote we have no write access to,
  # and a cycle must not care. One instance per process: the mirror warn
  # throttles on the last message, so a fresh instance per cycle silently
  # degrades to a warn a minute.
  class MasterSync
    Error = Class.new(StandardError)

    Result = Struct.new(:sha, :fetch_failed, :mirror_error, keyword_init: true)

    # master_ref derives from upstream_remote so that changing the remote alone
    # cannot leave the ref pointing at a remote that is no longer fetched: it
    # would resolve to nothing, fall back to the local master, and freeze the
    # planner on an ancient sha with only a non-ff mirror_error as the tell
    def initialize(repo, upstream_remote: "postgres", push_remote: "origin",
                   master_ref: nil, mirror: true)
      @repo = repo
      @upstream_remote = upstream_remote
      @push_remote = push_remote
      @master_ref = master_ref || "#{upstream_remote}/master"
      @mirror = mirror
      @last_mirror_error = nil
    end

    def call
      fetch = @repo.run("fetch", "--quiet", @upstream_remote, "master")
      # planning against a stale master is not fatal, but silence about it is.
      # Unthrottled, unlike the mirror warn below: every repeat means the sha
      # drifted another cycle further from reality, so the noise is the signal.
      # An unwritable mirror says the same thing forever.
      warn "master fetch failed: #{message(fetch.output)}" unless fetch.success?

      sha = @repo.rev_parse(@master_ref) || @repo.rev_parse("master")
      raise Error, "cannot resolve #{@master_ref}" unless sha

      # mirrors whatever resolved, the local fallback included: a stale sha is
      # either a no-op or a non-ff rejection, never a way to move the fork
      # backwards. Unconditional too, since one round trip a minute is cheaper
      # than tracking what the remote already has.
      Result.new(sha: sha, fetch_failed: !fetch.success?, mirror_error: mirror!(sha))
    end

    private

    # never --force: master only ever fast-forwards, and a rejected push is a
    # signal, not something to bulldoze. A remote we cannot write to must not
    # shout once a minute either, so only a changed message is news.
    def mirror!(sha)
      return nil unless @mirror

      result = @repo.run("push", @push_remote, "#{sha}:refs/heads/master")
      if result.success?
        @last_mirror_error = nil
        return nil
      end

      error = message(result.output)
      warn "master mirror push failed: #{error}" unless error == @last_mirror_error
      @last_mirror_error = error
      error
    end

    # git can fail with nothing on either stream, and an empty message would
    # make mirror_error a truthy blank while both warns read as cut off
    def message(text)
      text.to_s.scrub("?").strip.slice(0, 200).presence || "no output"
    end
  end
end
