class SeedIgnoredByMeSavedSearch < ActiveRecord::Migration[8.0]
  def up
    SavedSearch.find_or_create_by!(name: "Ignored by me", scope: "user", user_id: nil, team_id: nil) do |s|
      s.query = "ignored:me"
      s.position = 5
    end
  end

  def down
    SavedSearch.where(name: "Ignored by me", scope: "user", user_id: nil, team_id: nil).destroy_all
  end
end
