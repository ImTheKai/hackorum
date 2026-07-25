class CommitPerson < ApplicationRecord
  COMMITTER = "committer".freeze
  ROLES = %w[committer author reviewer reported_by tested_by co_author].freeze
  # Display order for the sidebar credits section.
  DISPLAY_ORDER = %w[author reviewer tested_by reported_by co_author committer].freeze

  belongs_to :commit
  belongs_to :person, optional: true

  validates :role, inclusion: { in: ROLES }
end
