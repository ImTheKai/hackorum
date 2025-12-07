class CreateContributors < ActiveRecord::Migration[8.0]
  def change
    create_enum :contributor_type, [
      "core_team",
      "committer",
      "major_contributor",
      "significant_contributor",
      "past_major_contributor",
      "past_significant_contributor"
    ]

    create_table :contributors do |t|
      t.string :name, null: false
      t.string :email
      t.enum :contributor_type, enum_type: :contributor_type, null: false
      t.string :profile_url

      t.timestamps
    end

    add_index :contributors, :email
    add_index :contributors, :contributor_type
  end
end
