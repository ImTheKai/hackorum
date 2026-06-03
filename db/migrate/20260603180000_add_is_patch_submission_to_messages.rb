class AddIsPatchSubmissionToMessages < ActiveRecord::Migration[8.0]
  def change
    add_column :messages, :is_patch_submission, :boolean, default: false, null: false
    add_index :messages, :is_patch_submission, where: "is_patch_submission = true"
  end
end
