class AddSendAuthToIdentities < ActiveRecord::Migration[8.0]
  def change
    add_column :identities, :refresh_token, :text
    add_column :identities, :access_token, :text
    add_column :identities, :access_token_expires_at, :datetime
    add_column :identities, :scopes, :text
    add_column :identities, :send_authorized_at, :datetime
    add_column :identities, :send_revoked_at, :datetime
    add_column :identities, :last_send_error, :text
  end
end
