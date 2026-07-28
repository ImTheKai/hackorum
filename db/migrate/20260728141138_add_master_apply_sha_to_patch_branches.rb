class AddMasterApplyShaToPatchBranches < ActiveRecord::Migration[8.0]
  # What the last master attempt was against, and what it found. Without the sha
  # a failure is unusable: master moves several times a day, so a set
  # master_apply_error cannot tell "conflicts with the master we have" from
  # "conflicted with some master last week". base_sha cannot stand in for it -
  # a failed attempt leaves the row's own base where it was, on purpose.
  def change
    add_column :patch_branches, :master_apply_sha, :string
    add_column :patch_branches, :master_conflict_files, :string, array: true, default: [], null: false
  end
end
