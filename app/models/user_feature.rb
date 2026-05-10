class UserFeature < ApplicationRecord
  belongs_to :user
  validates :feature, presence: true,
    inclusion: { in: Feature::NAMES, message: "is not a known feature" }
  validates :feature, uniqueness: { scope: :user_id }
end
