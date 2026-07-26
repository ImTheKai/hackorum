class AddCiOrchestration < ActiveRecord::Migration[8.0]
  def change
    add_column :patch_branches, :base_committed_at, :datetime
    add_column :patch_branches, :base_commit_height, :integer
    add_column :patch_branches, :superseded_by_id, :bigint
    add_column :patch_branches, :last_master_apply_at, :datetime
    add_column :patch_branches, :master_apply_error, :text
    add_index :patch_branches, :superseded_by_id
    add_index :patch_branches, :topic_id, where: "superseded_by_id IS NULL",
              name: "index_patch_branches_current_topic"
    add_foreign_key :patch_branches, :patch_branches, column: :superseded_by_id, on_delete: :nullify

    add_column :patch_ci_runs, :tests_total, :integer

    create_table :patch_ci_repo_states do |t|
      t.string :master_sha, null: false
      t.datetime :master_committed_at, null: false
      t.integer :master_commit_height, null: false
      t.datetime :fetched_at, null: false
      t.timestamps
    end
  end
end
