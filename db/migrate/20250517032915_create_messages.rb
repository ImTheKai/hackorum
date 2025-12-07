class CreateMessages < ActiveRecord::Migration[8.0]
  def change
    create_table :messages do |t|
      t.references :topic, foreign_key: true, index: true, null: false
      t.references :sender, foreign_key: { to_table: :aliases }, index: true, null: false
      t.references :reply_to, foreign_key: { to_table: :messages }, index: true, null: true
      t.string :subject, null: false
      t.string :message_id, null: true, index: { unique: true }
      t.text :body, null: false
      t.text :import_log

      t.timestamps
    end
  end
end
