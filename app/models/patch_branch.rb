class PatchBranch < ApplicationRecord
  STATUSES = %w[applied failed].freeze
  FAILURE_STAGES = %w[extract base_detection apply error].freeze

  belongs_to :topic
  belongs_to :message

  validates :branch_name, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :failure_stage, inclusion: { in: FAILURE_STAGES }, allow_nil: true

  scope :applied, -> { where(status: "applied") }
  scope :failed, -> { where(status: "failed") }
end
