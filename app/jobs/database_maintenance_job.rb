class DatabaseMaintenanceJob < ApplicationJob
  queue_as :default

  # Autovacuum triggers on write volume, but the tables that matter here are
  # large and written slowly, so proportional thresholds take months to trip.
  # A nightly pass bounds staleness by time instead: it refreshes planner stats
  # and, more importantly, the visibility map that keeps index-only scans from
  # falling back to heap fetches. Whole-database rather than a table list so it
  # does not go stale; takes a few seconds at current size.
  def perform
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # VACUUM cannot run inside a transaction block.
    ActiveRecord::Base.connection.execute("VACUUM (ANALYZE)")

    duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    Rails.logger.info("[DatabaseMaintenanceJob] VACUUM ANALYZE completed in #{duration.round(1)}s")
  end
end
