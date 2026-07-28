module PatchCi
  # The slow half of the loop. A full ref advertisement and a commit sweep have
  # no business running once a minute, so both are throttled; and they are kept
  # out of Orchestrator#cycle because sharing a repo is not sharing a purpose -
  # a broken import must never stop a push.
  class RepoMaintenance
    DEFAULT_INTERVAL = 1.hour

    Result = Struct.new(:ran, :fetch_error, :import_error, :skipped, keyword_init: true)

    def initialize(repo:, upstream_remote: "postgres", interval: DEFAULT_INTERVAL,
                   importer_factory: nil, on_progress: -> { }, logger: Rails.logger)
      @repo = repo
      @upstream_remote = upstream_remote
      @interval = interval
      @importer_factory = importer_factory || method(:default_importer)
      @on_progress = on_progress
      @logger = logger
      @last_run = nil
    end

    # ran: false means the window has not elapsed. The throttle is in memory on
    # purpose: after a restart an incremental import costs seconds, and a
    # persisted timestamp would be one more thing to keep true.
    def call(now: Time.current)
      return Result.new(ran: false) if @last_run && now - @last_run < @interval

      @last_run = now
      fetch_error = fetch_upstream!
      # a slow step must not read as a stalled process: the caller's liveness
      # signal is due here too, not just at the start and end of a cycle
      @on_progress.call
      import_error, skipped = import!
      Result.new(ran: true, fetch_error: fetch_error, import_error: import_error, skipped: skipped)
    end

    private

    # MasterSync only asks for master, every cycle. Tags and the stable
    # branches - everything release attribution reads - come from here.
    def fetch_upstream!
      result = @repo.run("fetch", "--prune", "--tags", @upstream_remote)
      return nil if result.success?

      clip(result.output).tap { |message| @logger.warn("repo maintenance: upstream fetch failed: #{message}") }
    end

    # Runs whatever the fetch outcome was: importing what we already have is
    # still worth its seconds, and a skipped hour of commits is not obviously
    # better than an hour-old view of them.
    # Returns [import_error, skipped] - a skip is not an error, but it must not
    # be indistinguishable from a clean run either: commits.released_in is
    # write-once, so a silently skipped hour never heals itself.
    def import!
      ran = false
      AdvisoryLock.with_lock(CommitImportJob::LOCK_KEY) do
        ran = true
        @importer_factory.call.run!
      end
      unless ran
        @logger.info("repo maintenance: commit import lock held, skipped")
        return [ nil, true ]
      end
      [ nil, false ]
    rescue StandardError => e
      message = clip("#{e.class}: #{e.message}")
      @logger.error("repo maintenance: commit import failed: #{message}")
      [ message, false ]
    end

    def default_importer
      CommitImport::Importer.new(
        repository: CommitImport::Repository.new(path: @repo.dir, upstream_remote: @upstream_remote),
        fetch: false,
        logger: @logger
      )
    end

    # collapses newlines too: this feeds a one-line orchestrator summary,
    # a multi-line git error must not split that record across lines
    def clip(text)
      text.to_s.scrub("?").gsub(/\s+/, " ").strip.slice(0, 200).presence || "no output"
    end
  end
end
