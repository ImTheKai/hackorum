# frozen_string_literal: true

class AddAwareBeforeToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :aware_before, :datetime
  end
end
