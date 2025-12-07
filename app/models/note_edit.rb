class NoteEdit < ApplicationRecord
  belongs_to :note
  belongs_to :editor, class_name: "User"

  validates :body, presence: true
end
