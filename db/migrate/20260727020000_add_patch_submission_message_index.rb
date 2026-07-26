class AddPatchSubmissionMessageIndex < ActiveRecord::Migration[8.0]
  def change
    add_index :messages, [ :topic_id, :created_at, :id ],
              order: { created_at: :desc, id: :desc },
              where: "is_patch_submission = TRUE",
              name: "index_messages_patch_submission_latest"
  end
end
