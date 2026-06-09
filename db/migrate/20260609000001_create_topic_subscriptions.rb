class CreateTopicSubscriptions < ActiveRecord::Migration[8.0]
  def change
    create_table :topic_subscriptions do |t|
      t.references :user, null: false, foreign_key: true
      t.references :topic, null: false, foreign_key: true
      t.string :unsubscribe_token, null: false

      t.timestamps
    end

    add_index :topic_subscriptions, :unsubscribe_token, unique: true
    add_index :topic_subscriptions, [:user_id, :topic_id], unique: true
  end
end
