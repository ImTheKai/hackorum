class NoteMention < ApplicationRecord
  belongs_to :note
  belongs_to :mentionable, polymorphic: true

  validates :mentionable_type, presence: true
  validates :mentionable_id, presence: true
end
