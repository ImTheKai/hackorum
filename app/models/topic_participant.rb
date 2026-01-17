class TopicParticipant < ApplicationRecord
  belongs_to :topic
  belongs_to :person

  scope :by_activity, -> { order(message_count: :desc) }
  scope :contributors, -> { where(is_contributor: true) }

  def display_alias
    person&.default_alias
  end
end
