# frozen_string_literal: true

require 'rails_helper'

RSpec.describe "Admin::ImapSyncStates", type: :request do
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

