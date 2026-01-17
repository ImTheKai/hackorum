class AddHasAttachmentsToTopics < ActiveRecord::Migration[8.0]
  def change
    add_column :topics, :has_attachments, :boolean, default: false, null: false
  end
end
