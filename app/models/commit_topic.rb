class CommitTopic < ApplicationRecord
  belongs_to :commit
  belongs_to :topic
end
