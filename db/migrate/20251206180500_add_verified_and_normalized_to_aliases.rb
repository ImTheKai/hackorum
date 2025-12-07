class AddVerifiedAndNormalizedToAliases < ActiveRecord::Migration[8.0]
  def change
    add_column :aliases, :verified_at, :datetime
    # Functional index for case/space-insensitive email lookups
    execute <<~SQL
      CREATE INDEX IF NOT EXISTS index_aliases_on_lower_trim_email
      ON aliases (lower(trim(email)));
    SQL
  end
end
