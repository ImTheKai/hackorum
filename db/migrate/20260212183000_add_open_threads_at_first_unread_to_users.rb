# frozen_string_literal: true

class AddOpenThreadsAtFirstUnreadToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :open_threads_at_first_unread, :boolean, default: false, null: false
  end
end
