class TuneAutovacuumForHotTables < ActiveRecord::Migration[8.0]
  # Autovacuum thresholds are proportional to table size, so on messages
  # (1M rows) the stock 0.2 insert scale factor needs ~200k new rows before the
  # visibility map is refreshed. At the normal ingest rate of ~130 messages/day
  # that is years, which is why these tables had never been vacuumed or
  # analyzed. Steady state is handled by DatabaseMaintenanceJob nightly.
  #
  # What a nightly job cannot cover is a bulk import: the commitfest and archive
  # backfills insert six figures of rows in one run, and the planner would work
  # from pre-import stats until the next night. Flat thresholds trigger on volume
  # rather than proportion, so they fire during the import instead.
  SETTINGS = {
    messages: {
      autovacuum_analyze_scale_factor: 0.0,
      autovacuum_analyze_threshold: 20_000,
      autovacuum_vacuum_insert_scale_factor: 0.0,
      autovacuum_vacuum_insert_threshold: 50_000
    },
    topic_participants: {
      autovacuum_analyze_scale_factor: 0.0,
      autovacuum_analyze_threshold: 20_000
    },
    topics: {
      autovacuum_analyze_scale_factor: 0.0,
      autovacuum_analyze_threshold: 5_000
    }
  }.freeze

  def up
    SETTINGS.each do |table, options|
      assignments = options.map { |k, v| "#{k} = #{v}" }.join(", ")
      execute "ALTER TABLE #{table} SET (#{assignments})"
    end

    # These tables have never been analyzed, so the planner is working from
    # nothing. Give it a starting point rather than waiting for the first
    # nightly run.
    SETTINGS.each_key { |table| execute "ANALYZE #{table}" }
  end

  def down
    SETTINGS.each do |table, options|
      execute "ALTER TABLE #{table} RESET (#{options.keys.join(', ')})"
    end
  end
end
