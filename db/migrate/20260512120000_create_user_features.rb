class CreateUserFeatures < ActiveRecord::Migration[8.0]
  def change
    create_table :user_features do |t|
      t.references :user, null: false, foreign_key: true
      t.string :feature, null: false
      t.datetime :created_at, null: false
    end
    add_index :user_features, [ :user_id, :feature ], unique: true
  end
end
