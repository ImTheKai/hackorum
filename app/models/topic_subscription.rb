class TopicSubscription < ApplicationRecord
  belongs_to :user
  belongs_to :topic

  has_secure_token :unsubscribe_token

  validates :user_id, uniqueness: { scope: :topic_id }
end
