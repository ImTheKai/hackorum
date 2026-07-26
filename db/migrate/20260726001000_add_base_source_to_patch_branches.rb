class AddBaseSourceToPatchBranches < ActiveRecord::Migration[8.0]
  def change
    add_column :patch_branches, :base_source, :string
  end
end
