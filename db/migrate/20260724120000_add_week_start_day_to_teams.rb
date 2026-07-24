class AddWeekStartDayToTeams < ActiveRecord::Migration[8.0]
  def change
    add_column :teams, :week_start_day, :integer, default: 1, null: false
  end
end
