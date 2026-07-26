class CreatePatchCiRuns < ActiveRecord::Migration[8.0]
  def change
    create_table :patch_ci_runs do |t|
      t.references :patch_branch, null: false, foreign_key: { on_delete: :cascade }, index: true
      t.bigint :github_run_id, null: false
      t.integer :run_attempt, null: false, default: 1
      t.string :head_sha
      t.integer :pg_major
      t.string :status, null: false
      t.string :conclusion
      t.datetime :queued_at
      t.datetime :started_at
      t.datetime :completed_at
      t.integer :build_seconds
      t.integer :test_seconds
      t.string :failed_tests, array: true, null: false, default: []
      t.string :image_ref
      t.string :image_digest
      t.jsonb :payload
      t.timestamps
    end

    add_index :patch_ci_runs, [ :github_run_id, :run_attempt ], unique: true

    add_column :patch_branches, :pushed_head_sha, :string
    add_column :patch_branches, :latest_ci_run_id, :bigint
    add_column :patch_branches, :ci_status, :string
    add_column :patch_branches, :ci_skip_reason, :string
    add_index :patch_branches, :ci_status
    add_index :patch_branches, :latest_ci_run_id
    add_foreign_key :patch_branches, :patch_ci_runs,
                    column: :latest_ci_run_id, on_delete: :nullify

    # message re-import deletes messages; without cascade the patch_branches FK
    # blocks it, and patch_ci_runs would make that worse
    remove_foreign_key :patch_branches, :messages
    add_foreign_key :patch_branches, :messages, on_delete: :cascade
  end
end
