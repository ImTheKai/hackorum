# frozen_string_literal: true

class Team < ApplicationRecord
  has_many :team_members, dependent: :destroy
  has_many :users, through: :team_members

  validates :name, presence: true
  validates :name, format: { with: /\A[a-zA-Z0-9_\-\.]+\z/ }

  after_commit :reserve_name, on: :create
  after_destroy :release_name_reservation

  def member?(user)
    return false unless user
    team_members.exists?(user_id: user.id)
  end

  def admin?(user)
    return false unless user
    team_members.role_admin.exists?(user_id: user.id)
  end

  def last_admin?(team_member)
    return false unless team_member.admin?
    team_members.role_admin.count == 1
  end

  private

  def reserve_name
    NameReservation.reserve!(name:, owner: self)
  end

  def release_name_reservation
    NameReservation.release_for(self)
  end
end
