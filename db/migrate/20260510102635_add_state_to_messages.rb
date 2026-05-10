class AddStateToMessages < ActiveRecord::Migration[8.0]
  def up
    add_column :messages, :state, :string, default: "sent", null: false
    add_column :messages, :sent_at, :datetime
    add_column :messages, :sent_via_identity_id, :bigint
    add_column :messages, :sent_to_address, :string
    add_index :messages, :state
    add_foreign_key :messages, :identities, column: :sent_via_identity_id
  end

  def down
    remove_foreign_key :messages, column: :sent_via_identity_id
    remove_index :messages, :state
    remove_column :messages, :sent_to_address
    remove_column :messages, :sent_via_identity_id
    remove_column :messages, :sent_at
    remove_column :messages, :state
  end
end
