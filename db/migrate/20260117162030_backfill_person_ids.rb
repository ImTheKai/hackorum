class BackfillPersonIds < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    # Backfill topics - join with aliases to get person_id
    execute <<~SQL
      UPDATE topics
      SET creator_person_id = aliases.person_id
      FROM aliases
      WHERE topics.creator_id = aliases.id
        AND topics.creator_person_id IS NULL
    SQL

    # Backfill messages - join with aliases to get person_id
    execute <<~SQL
      UPDATE messages
      SET sender_person_id = aliases.person_id
      FROM aliases
      WHERE messages.sender_id = aliases.id
        AND messages.sender_person_id IS NULL
    SQL

    # Backfill mentions - join with aliases to get person_id
    execute <<~SQL
      UPDATE mentions
      SET person_id = aliases.person_id
      FROM aliases
      WHERE mentions.alias_id = aliases.id
        AND mentions.person_id IS NULL
    SQL
  end

  def down
    # No-op: columns remain nullable until enforcement migration
  end
end
