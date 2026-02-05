# frozen_string_literal: true

require 'rails_helper'

RSpec.describe "Admin::ImapSyncStates", type: :request do
  def sign_in(email:, password: "secret")
    post session_path, params: { email: email, password: password }
    expect(response).to redirect_to(root_path)
  end

  def attach_verified_alias(user, email:)
    al = create(:alias, user: user, email: email)
    user.person.update!(default_alias_id: al.id) if user.person&.default_alias_id.nil?
    Alias.by_email(email).update_all(verified_at: Time.current)
    al
  end

  let!(:admin_user) { create(:user, password: "secret", password_confirmation: "secret", admin: true) }

  before do
    attach_verified_alias(admin_user, email: "admin@example.com")
    sign_in(email: "admin@example.com")
  end

  it 'renders JSON with metrics' do
    ImapSyncState.create!(mailbox_label: 'INBOX', last_uid: 42, last_fetched_count: 3, last_ingested_count: 2)
    get "/admin/imap_sync_states.json"
    expect(response).to have_http_status(:ok)
    json = JSON.parse(response.body)
    expect(json).to be_a(Array)
    expect(json.first).to include('mailbox_label' => 'INBOX', 'last_uid' => 42)
  end

  it 'renders HTML table' do
    ImapSyncState.create!(mailbox_label: 'INBOX')
    get "/admin/imap_sync_states"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('IMAP Sync Status')
  end
end
