class CreateMentions < ActiveRecord::Migration[8.0]
  def change
    create_table :mentions do |t|
      t.references :message, null: false, foreign_key: true, null: false
      t.references :alias, null: false, foreign_key: true, null: false

      t.timestamps
    end
  end
end
