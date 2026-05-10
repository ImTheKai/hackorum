class OutgoingDraft < ApplicationRecord
  STATUS_IDLE    = "idle"
  STATUS_SENDING = "sending"

  belongs_to :user
  belongs_to :topic
  belongs_to :reply_to_message, class_name: "Message"
  belongs_to :sender_alias, class_name: "Alias"
  belongs_to :identity

  validates :subject, presence: true
  validates :status, inclusion: { in: [STATUS_IDLE, STATUS_SENDING] }
  validates :user_id, uniqueness: { scope: :reply_to_message_id }

  scope :idle,    -> { where(status: STATUS_IDLE) }
  scope :sending, -> { where(status: STATUS_SENDING) }
  scope :stale_sending, ->(threshold = 10.minutes.ago) {
    sending.where("sending_started_at < ?", threshold)
  }

  def idle?    = status == STATUS_IDLE
  def sending? = status == STATUS_SENDING
end
