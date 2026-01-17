class EnforcePersonIdConstraints < ActiveRecord::Migration[8.0]
  def change
    # Validate the foreign keys that were added with validate: false
    validate_foreign_key :topics, :people, column: :creator_person_id
    validate_foreign_key :messages, :people, column: :sender_person_id
    validate_foreign_key :mentions, :people, column: :person_id

    # Now enforce NOT NULL after backfill is complete
    change_column_null :topics, :creator_person_id, false
    change_column_null :messages, :sender_person_id, false
    change_column_null :mentions, :person_id, false
  end
end
