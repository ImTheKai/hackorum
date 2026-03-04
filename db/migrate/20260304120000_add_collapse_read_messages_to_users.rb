# frozen_string_literal: true

class AddCollapseReadMessagesToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :collapse_read_messages, :boolean, default: true, null: false
  end
end
