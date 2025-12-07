class CreateAttachments < ActiveRecord::Migration[8.0]
  def change
    create_table :attachments do |t|
      t.references :message, foreign_key: true, index: true, null: false
      t.string :file_name, null: false
      t.string :content_type
      t.text   :body

      t.timestamps
    end
  end
end
