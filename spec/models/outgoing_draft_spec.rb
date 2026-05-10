require 'rails_helper'

RSpec.describe OutgoingDraft, type: :model do
  it 'is uniquely keyed by (user, reply_to_message)' do
    draft = create(:outgoing_draft)
    dup   = build(:outgoing_draft,
                  user: draft.user,
                  reply_to_message: draft.reply_to_message,
                  topic: draft.topic)
    expect(dup).not_to be_valid
  end

  it 'scopes idle and sending' do
    a = create(:outgoing_draft, status: 'idle')
    b = create(:outgoing_draft, status: 'sending', sending_started_at: 1.minute.ago)
    expect(OutgoingDraft.idle).to contain_exactly(a)
    expect(OutgoingDraft.sending).to contain_exactly(b)
  end

  it 'flags stale sending rows' do
    fresh = create(:outgoing_draft, status: 'sending', sending_started_at: 1.minute.ago)
    stale = create(:outgoing_draft, status: 'sending', sending_started_at: 1.hour.ago)
    expect(OutgoingDraft.stale_sending).to contain_exactly(stale)
  end
end
