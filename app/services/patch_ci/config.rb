module PatchCi
  # every tunable in one place (script entry points default to nil at
  # optparse time and fill in from here after rails loads)
  module Config
    BUDGET = 30                 # queued+running target on github
    IN_PROGRESS_LIST = 40
    UP_NEXT_LIST = 30
    RECENT_LIST = 50
    BRANCHES_PAGE = 100         # /ci/branches page size
    REBASE_AFTER_DAYS = 30      # base older than this vs master -> rebase due
    ANCIENT_AFTER_DAYS = 365    # base older than a major release cycle; keep above REBASE_AFTER_DAYS
    ACTIVE_THREAD_DAYS = 30     # thread with newer messages counts as active
    STUCK_RUN_HOURS = 48        # pushed but no verdict -> infra_error
    PUSH_RETRY_MINUTES = 30     # backoff before retrying a push_failed row
    RESULT_REF_KEEP_DAYS = 14   # refs/hackorum-ci retention after ingest
    # backstop on the cached whole-table aggregates: the cache key carries the
    # repo state's fetched_at, so a live orchestrator turns them over sooner
    AGGREGATE_TTL = 1.minute
    WORK_FROM = Time.zone.parse("2017-01-01").freeze # commit status floor, same as backfill
  end
end
