class CreateUsers < ActiveRecord::Migration[8.0]
  def change
    create_table :users do |t|
      # TODO: name should also be unique to avoid confusion
      t.timestamps
    end
  end
end
