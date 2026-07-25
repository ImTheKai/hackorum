class CommitImportJob < ApplicationJob
  queue_as :default

  LOCK_KEY = "commit_import".freeze

  def perform
    ran = false
    AdvisoryLock.with_lock(LOCK_KEY) do
      ran = true
      CommitImport::Importer.new.run!
    end
    Rails.logger.info("[CommitImportJob] skipped, lock #{LOCK_KEY} already held") unless ran
  end
end
