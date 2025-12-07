class Activity < ApplicationRecord
  belongs_to :user
  belongs_to :subject, polymorphic: true

  scope :visible, -> { where(hidden: false) }
  scope :unread, -> { visible.where(read_at: nil) }

  def mark_read!
    update!(read_at: Time.current)
  end
end
