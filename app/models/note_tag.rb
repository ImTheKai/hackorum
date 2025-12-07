class NoteTag < ApplicationRecord
  TAG_FORMAT = /\A[a-z0-9][a-z0-9_.\-]*\z/

  belongs_to :note

  before_validation :normalize_tag

  validates :tag, presence: true, format: { with: TAG_FORMAT }
  validates :tag, uniqueness: { scope: :note_id }

  private

  def normalize_tag
    self.tag = tag.to_s.strip.downcase
  end
end
