class AddLastMessageIdToTopics < ActiveRecord::Migration[8.0]
  def up
    add_column :topics, :last_message_id, :bigint
    add_foreign_key :topics, :messages, column: :last_message_id

    execute <<~SQL
      UPDATE topics
      SET last_message_id = subq.max_id
      FROM (
        SELECT topic_id, MAX(id) AS max_id
        FROM messages
        GROUP BY topic_id
      ) subq
      WHERE topics.id = subq.topic_id
    SQL
  end

  def down
    remove_foreign_key :topics, column: :last_message_id
    remove_column :topics, :last_message_id
  end
end
