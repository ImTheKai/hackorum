class CreatePatchBranches < ActiveRecord::Migration[8.0]
  def change
    create_table :patch_branches do |t|
      t.bigint :topic_id, null: false
      t.bigint :message_id, null: false
      t.string :branch_name, null: false
      t.string :base_sha
      t.boolean :on_master, default: false, null: false
      t.string :status, null: false
      t.string :failure_stage
      t.text :failure_reason
      t.string :conflict_files, array: true, default: [], null: false
      t.string :patch_content_hash
      t.datetime :attempted_at
      t.datetime :pushed_at
      t.timestamps

      t.index :message_id, unique: true
      t.index :branch_name, unique: true
      t.index :topic_id
      t.index [ :status, :failure_stage ]
    end

    add_foreign_key :patch_branches, :topics
    add_foreign_key :patch_branches, :messages
  end
end
