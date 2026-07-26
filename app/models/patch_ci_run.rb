class PatchCiRun < ApplicationRecord
  STATUSES = %w[
    ci_none pushed_awaiting_ci push_failed queued running success
    build_failed build_timeout tests_failed tests_timeout
    cancelled infra_error
  ].freeze

  TERMINAL_STATUSES = %w[
    success build_failed build_timeout tests_failed tests_timeout
    cancelled infra_error
  ].freeze

  belongs_to :patch_branch

  validates :github_run_id, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :terminal, -> { where(status: TERMINAL_STATUSES) }

  def terminal?
    TERMINAL_STATUSES.include?(status)
  end
end
