class AddParticipantFieldsToTopics < ActiveRecord::Migration[8.0]
  def change
    add_column :topics, :participant_count, :integer, default: 0, null: false
    add_column :topics, :contributor_participant_count, :integer, default: 0, null: false
    add_column :topics, :highest_contributor_type, :enum, enum_type: :contributor_type
    add_column :topics, :last_message_at, :datetime
    add_column :topics, :last_sender_person_id, :bigint
    add_column :topics, :message_count, :integer, default: 0, null: false

    add_foreign_key :topics, :people, column: :last_sender_person_id
    add_index :topics, :last_message_at
  end
end
