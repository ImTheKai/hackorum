class FixSupersededByFkNullify < ActiveRecord::Migration[8.0]
  def change
    remove_foreign_key :patch_branches, :patch_branches, column: :superseded_by_id
    add_foreign_key :patch_branches, :patch_branches, column: :superseded_by_id, on_delete: :nullify
  end
end
