class ResyncStaleTopicLastMessage < ActiveRecord::Migration[8.0]
  # Correcting a mail Date: rewrote messages.created_at without refreshing the
  # topic's cached latest-message columns, so some topics point at a stale
  # timestamp. Harmless while the list recomputed MAX() on every load, wrong now
  # that it reads the column.
  def up
    execute <<~SQL
      WITH actual AS (
        SELECT m.topic_id,
               MAX(m.created_at) AS last_message_at,
               (ARRAY_AGG(m.id ORDER BY m.created_at DESC, m.id DESC))[1] AS last_message_id
        FROM messages m
        GROUP BY m.topic_id
      )
      UPDATE topics t
      SET last_message_at = actual.last_message_at,
          last_message_id = actual.last_message_id,
          last_sender_person_id = m.sender_person_id
      FROM actual
      JOIN messages m ON m.id = actual.last_message_id
      WHERE actual.topic_id = t.id
        AND (t.last_message_at, t.last_message_id) IS DISTINCT FROM
            (actual.last_message_at, actual.last_message_id)
    SQL

    # Participant rows drift for the same reason.
    execute <<~SQL
      WITH actual AS (
        SELECT m.topic_id,
               m.sender_person_id,
               MIN(m.created_at) AS first_message_at,
               MAX(m.created_at) AS last_message_at
        FROM messages m
        GROUP BY m.topic_id, m.sender_person_id
      )
      UPDATE topic_participants tp
      SET first_message_at = actual.first_message_at,
          last_message_at = actual.last_message_at
      FROM actual
      WHERE actual.topic_id = tp.topic_id
        AND actual.sender_person_id = tp.person_id
        AND (tp.first_message_at, tp.last_message_at) IS DISTINCT FROM
            (actual.first_message_at, actual.last_message_at)
    SQL
  end

  def down
    # Data repair, nothing to restore.
  end
end
