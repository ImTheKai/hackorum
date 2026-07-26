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

  # a branch whose CI is still out there somewhere: pushed but unclaimed, or
  # running. Force-pushing one burns the slot, so every consumer needs the
  # same list - dashboards, the rebase tier, the stuck marker
  IN_FLIGHT_BRANCH_STATUSES = %w[pushed_awaiting_ci queued running].freeze

  belongs_to :patch_branch

  validates :github_run_id, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :terminal, -> { where(status: TERMINAL_STATUSES) }

  # payload is up to 256KB of github json per row - never haul it into a list.
  # Lazy, not a constant: column_names queries, and a class body that needs the
  # database cannot be eager-loaded with the database down - which is exactly
  # when you want a console.
  def self.list_columns
    @list_columns ||= (column_names - %w[payload]).map(&:to_sym).freeze
  end

  def terminal?
    TERMINAL_STATUSES.include?(status)
  end
end
