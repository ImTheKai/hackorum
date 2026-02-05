class CreateAdminEmailChanges < ActiveRecord::Migration[8.0]
  def change
    create_table :admin_email_changes do |t|
      t.references :performed_by, null: false, foreign_key: { to_table: :users }
      t.references :target_user, null: false, foreign_key: { to_table: :users }
      t.string :email, null: false
      t.integer :aliases_attached, null: false, default: 0
      t.boolean :created_new_alias, null: false, default: false
      t.timestamps
    end
  end
end
