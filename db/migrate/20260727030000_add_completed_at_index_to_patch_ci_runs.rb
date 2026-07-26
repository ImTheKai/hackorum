class AddCompletedAtIndexToPatchCiRuns < ActiveRecord::Migration[8.0]
  def change
    add_index :patch_ci_runs, :completed_at, order: { completed_at: :desc }
  end
end
