class Contributor < ApplicationRecord
  has_and_belongs_to_many :aliases

  enum :contributor_type, {
    core_team: "core_team",
    committer: "committer",
    major_contributor: "major_contributor",
    significant_contributor: "significant_contributor",
    past_major_contributor: "past_major_contributor",
    past_significant_contributor: "past_significant_contributor"
  }

  validates :name, presence: true

  scope :core_team, -> { where(contributor_type: :core_team) }
  scope :committers, -> { where(contributor_type: :committer) }
  scope :major_contributors, -> { where(contributor_type: :major_contributor) }
  scope :significant_contributors, -> { where(contributor_type: :significant_contributor) }
  scope :past_major_contributors, -> { where(contributor_type: :past_major_contributor) }
  scope :past_significant_contributors, -> { where(contributor_type: :past_significant_contributor) }

  scope :current, -> { where(contributor_type: [:core_team, :committer, :major_contributor, :significant_contributor]) }
  scope :past, -> { where(contributor_type: [:past_major_contributor, :past_significant_contributor]) }

  def past_contributor?
    past_major_contributor? || past_significant_contributor?
  end

  def current_contributor?
    !past_contributor?
  end
end
