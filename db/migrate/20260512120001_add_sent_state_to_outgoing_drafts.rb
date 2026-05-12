class AddSentStateToOutgoingDrafts < ActiveRecord::Migration[8.0]
  def up
    add_reference :outgoing_drafts, :sent_message,
                  foreign_key: { to_table: :messages }, null: true
    add_column    :outgoing_drafts, :sent_at, :datetime, null: true

    remove_index :outgoing_drafts, name: :idx_drafts_user_parent_unique
    add_index :outgoing_drafts, [:user_id, :reply_to_message_id],
              unique: true,
              where: "status IN ('idle','sending')",
              name:  :idx_drafts_user_parent_active_unique
  end

  def down
    remove_index :outgoing_drafts, name: :idx_drafts_user_parent_active_unique
    add_index :outgoing_drafts, [:user_id, :reply_to_message_id],
              unique: true, name: :idx_drafts_user_parent_unique

    remove_column    :outgoing_drafts, :sent_at
    remove_reference :outgoing_drafts, :sent_message,
                     foreign_key: { to_table: :messages }
  end
end
