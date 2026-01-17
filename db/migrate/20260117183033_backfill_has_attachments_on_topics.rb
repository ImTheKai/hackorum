class BackfillHasAttachmentsOnTopics < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      UPDATE topics
      SET has_attachments = true
      WHERE id IN (
        SELECT DISTINCT messages.topic_id
        FROM attachments
        INNER JOIN messages ON messages.id = attachments.message_id
      )
    SQL
  end

  def down
    execute "UPDATE topics SET has_attachments = false"
  end
end
