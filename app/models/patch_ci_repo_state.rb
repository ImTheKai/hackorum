class PatchCiRepoState < ApplicationRecord
  STALE_AFTER = 5.minutes

  validates :master_sha, :master_committed_at, :master_commit_height, :fetched_at, presence: true

  def self.current
    order(:id).first
  end

  def self.refresh!(master_sha:, master_committed_at:, master_commit_height:)
    state = current || new
    state.update!(master_sha: master_sha, master_committed_at: master_committed_at,
                  master_commit_height: master_commit_height, fetched_at: Time.current)
    state
  end

  def stale?
    fetched_at < STALE_AFTER.ago
  end
end
