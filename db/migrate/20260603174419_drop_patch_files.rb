class DropPatchFiles < ActiveRecord::Migration[8.0]
  def change
    drop_table :patch_files do |t|
      t.references :attachment, null: false, foreign_key: true
      t.string :filename, null: false
      t.string :status
      t.integer :line_changes
      t.string :old_filename
      t.timestamps
      t.index :filename
      t.index [ :attachment_id, :filename ], unique: true
    end

    remove_column :imap_sync_states, :last_patch_files_count, :integer
  end
end
