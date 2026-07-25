module CommitImport
  class Error < StandardError; end

  DEFAULT_REPO_PATH = "/pgrepo".freeze

  def self.repo_path
    ENV.fetch("HACKORUM_PG_REPO", DEFAULT_REPO_PATH)
  end
end
