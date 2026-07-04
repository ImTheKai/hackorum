class CreatePatchSubmissionFiles < ActiveRecord::Migration[8.0]
  def change
    create_table :patch_submission_files do |t|
      t.references :message, null: false, foreign_key: true, index: false
      t.string :path, null: false
      t.index [ :message_id, :path ], unique: true
    end
  end
end
