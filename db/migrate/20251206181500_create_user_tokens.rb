class CreateUserTokens < ActiveRecord::Migration[8.0]
  def change
    create_table :user_tokens do |t|
      t.references :user, null: true, foreign_key: true
      t.string :email
      t.string :purpose, null: false
      t.string :token_digest, null: false
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.text :metadata

      t.timestamps
    end

    add_index :user_tokens, :token_digest
    add_index :user_tokens, :purpose
    add_index :user_tokens, :consumed_at
    # Functional index for email lookups
    execute <<~SQL
      CREATE INDEX IF NOT EXISTS index_user_tokens_on_lower_trim_email
      ON user_tokens (lower(trim(email)));
    SQL
  end
end
