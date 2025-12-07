class Alias < ApplicationRecord
  belongs_to :user, optional: true
  has_many :topics, class_name: 'Topic', foreign_key: "creator_id", inverse_of: :creator
  has_many :messages, class_name: 'Message', foreign_key: "sender_id", inverse_of: :sender
  has_many :attachments, through: :messages
  has_and_belongs_to_many :contributors

  validates :name, presence: true
  validates :email, presence: true
  validates :name, uniqueness: { scope: :email }

  validate :only_one_primary_alias_per_user

  scope :by_email, ->(email) {
    where("lower(trim(email)) = lower(trim(?))", email)
  }

  def gravatar_url(size: 80)
    require 'digest/md5'
    hash = Digest::MD5.hexdigest(email.downcase.strip)
    "https://www.gravatar.com/avatar/#{hash}?s=#{size}&d=identicon"
  end

  def contributor
    # Return the highest-priority contributor if multiple exist
    # Priority: core_team > committer > major > significant > past_major > past_significant
    @contributor ||= contributors.order(
      Arel.sql("CASE contributor_type
        WHEN 'core_team' THEN 1
        WHEN 'committer' THEN 2
        WHEN 'major_contributor' THEN 3
        WHEN 'significant_contributor' THEN 4
        WHEN 'past_major_contributor' THEN 5
        WHEN 'past_significant_contributor' THEN 6
        ELSE 7
      END")
    ).first
  end

  def contributor?
    contributors.any?
  end

  def contributor_type
    contributor&.contributor_type
  end

  def core_team?
    contributors.any?(&:core_team?)
  end

  def committer?
    contributors.any?(&:committer?)
  end

  def major_contributor?
    contributors.any?(&:major_contributor?)
  end

  def significant_contributor?
    contributors.any?(&:significant_contributor?)
  end

  def contributor_badge
    return nil unless contributor?

    case contributor_type
    when 'core_team' then 'Core Team'
    when 'committer' then 'Committer'
    when 'major_contributor' then 'Major Contributor'
    when 'significant_contributor' then 'Contributor'
    when 'past_major_contributor' then 'Past Contributor'
    when 'past_significant_contributor' then 'Past Contributor'
    end
  end

  private

  def only_one_primary_alias_per_user
    return unless user_id && primary_alias?
    conflict = Alias.where(user_id: user_id, primary_alias: true)
    conflict = conflict.where.not(id: id) if persisted?
    errors.add(:primary_alias, 'only one primary alias per user') if conflict.exists?
  end
end
