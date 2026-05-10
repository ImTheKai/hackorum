class Identity < ApplicationRecord
  belongs_to :user

  encrypts :refresh_token
  encrypts :access_token

  validates :provider, presence: true
  validates :uid, presence: true
  validates :uid, uniqueness: { scope: :provider }

  scope :send_authorized, -> {
    where.not(refresh_token: nil).where(send_revoked_at: nil)
  }

  def send_authorized?
    !refresh_token.nil? && send_revoked_at.nil?
  end
end
