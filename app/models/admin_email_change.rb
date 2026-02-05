# frozen_string_literal: true

class AdminEmailChange < ApplicationRecord
  belongs_to :performed_by, class_name: "User"
  belongs_to :target_user, class_name: "User"

  validates :email, presence: true
end
