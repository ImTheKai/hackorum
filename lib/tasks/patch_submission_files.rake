namespace :patch_submission_files do
  desc "Backfill extracted diff paths. FROM=2000-01-01 TO=2014-02-01"
  task backfill: :environment do
    PatchPathExtractor.backfill(
      from: Time.zone.parse(ENV.fetch("FROM", "2000-01-01")),
      to: Time.zone.parse(ENV.fetch("TO", Time.current.iso8601))
    )
  end
end
