class PatchBranch < ApplicationRecord
  STATUSES = %w[applied failed].freeze
  FAILURE_STAGES = %w[extract base_detection apply error].freeze

  belongs_to :topic
  belongs_to :message
  has_many :ci_runs, class_name: "PatchCiRun", dependent: :destroy
  belongs_to :latest_ci_run, class_name: "PatchCiRun", optional: true

  validates :branch_name, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :failure_stage, inclusion: { in: FAILURE_STAGES }, allow_nil: true
  validates :ci_status, inclusion: { in: PatchCiRun::STATUSES }, allow_nil: true

  scope :applied, -> { where(status: "applied") }
  scope :failed, -> { where(status: "failed") }
  scope :pushed, -> { where.not(pushed_at: nil) }
  scope :awaiting_ci, -> { where(ci_status: "pushed_awaiting_ci") }
end
