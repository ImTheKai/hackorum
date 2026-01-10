# frozen_string_literal: true

class AutoStarTopicsForExistingUsers < ActiveRecord::Migration[8.0]
  def up
    one_year_ago = 1.year.ago

    execute <<-SQL
      INSERT INTO topic_stars (user_id, topic_id, created_at, updated_at)
      SELECT DISTINCT
        aliases.user_id,
        messages.topic_id,
        NOW(),
        NOW()
      FROM messages
      INNER JOIN aliases ON aliases.id = messages.sender_id
      INNER JOIN topics ON topics.id = messages.topic_id
      WHERE aliases.user_id IS NOT NULL
        AND topics.updated_at >= '#{one_year_ago.to_fs(:db)}'
        AND NOT EXISTS (
          SELECT 1 FROM topic_stars
          WHERE topic_stars.user_id = aliases.user_id
            AND topic_stars.topic_id = messages.topic_id
        )
    SQL
  end

  def down
  end
end
