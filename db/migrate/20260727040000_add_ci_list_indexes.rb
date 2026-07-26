class AddCiListIndexes < ActiveRecord::Migration[8.0]
  def change
    add_index :patch_ci_runs, [ :created_at, :id ], order: { created_at: :desc, id: :desc }
    add_index :patch_branches, :attempted_at, order: { attempted_at: :desc }
  end
end
