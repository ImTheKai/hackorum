# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ImapSyncState, type: :model do
  it 'creates or finds by label with default values' do
    state = described_class.for_label('INBOX')
    expect(state.mailbox_label).to eq('INBOX')
    expect(state.last_uid).to be_a(Integer)
  end

  it 'enforces uniqueness by mailbox_label' do
    described_class.for_label('INBOX')
    expect { described_class.create!(mailbox_label: 'INBOX') }.to raise_error(ActiveRecord::RecordInvalid)
  end
end
