class CreateTopics < ActiveRecord::Migration[8.0]
  def change
    create_table :topics do |t|
      t.string :title, null: false
      t.references :creator, foreign_key: { to_table: :aliases }, index: true, null: false

      t.timestamps
    end
  end
end
