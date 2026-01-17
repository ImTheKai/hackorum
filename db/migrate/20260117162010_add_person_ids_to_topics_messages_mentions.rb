class AddPersonIdsToTopicsMessagesMentions < ActiveRecord::Migration[8.0]
  def change
    # Add nullable person_id columns
    add_column :topics, :creator_person_id, :bigint
    add_column :messages, :sender_person_id, :bigint
    add_column :mentions, :person_id, :bigint

    # Add indexes for efficient lookups
    add_index :topics, :creator_person_id
    add_index :messages, :sender_person_id
    add_index :mentions, :person_id

    # Add foreign keys (validate: false for safe deployment)
    add_foreign_key :topics, :people, column: :creator_person_id, validate: false
    add_foreign_key :messages, :people, column: :sender_person_id, validate: false
    add_foreign_key :mentions, :people, column: :person_id, validate: false
  end
end
