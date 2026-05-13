class CreateOutgoingDrafts < ActiveRecord::Migration[8.0]
  def change
    create_table :outgoing_drafts do |t|
      t.references :user,             null: false, foreign_key: true
      t.references :topic,            null: false, foreign_key: true
      t.references :reply_to_message, null: false, foreign_key: { to_table: :messages }
      t.references :sender_alias,     null: false, foreign_key: { to_table: :aliases }
      t.references :identity,         null: false, foreign_key: true
      t.string  :subject, null: false
      t.text    :body,    null: false, default: ""
      t.string  :status,  null: false, default: "idle"
      t.text    :last_send_error
      t.datetime :sending_started_at
      t.timestamps
    end
    add_index :outgoing_drafts, [ :user_id, :reply_to_message_id ], unique: true,
              name: "idx_drafts_user_parent_unique"
  end
end
