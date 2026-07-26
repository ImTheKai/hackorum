class AddPgMajorToPatchBranches < ActiveRecord::Migration[8.0]
  def change
    add_column :patch_branches, :pg_major, :integer
    add_index :patch_branches, :pg_major
    # the default /ci/branches sort, and the reason BranchQuery::SORTS only asks
    # for NULLS LAST on the nullable columns - this one must stay usable
    add_index :patch_branches, [ :updated_at, :id ],
              order: { updated_at: :desc, id: :desc },
              name: "index_patch_branches_on_updated_at_and_id"
  end
end
