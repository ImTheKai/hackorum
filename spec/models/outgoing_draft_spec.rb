require 'rails_helper'

RSpec.describe OutgoingDraft, type: :model do
  it 'is uniquely keyed by (user, reply_to_message) among active drafts' do
    draft = create(:outgoing_draft)
    dup   = build(:outgoing_draft,
                  user: draft.user,
                  reply_to_message: draft.reply_to_message,
                  topic: draft.topic)
    expect(dup).not_to be_valid
  end

  it 'allows a new active draft after a sent one to the same parent' do
    sent = create(:outgoing_draft, status: 'sent', sent_at: Time.current)
    new_one = build(:outgoing_draft,
                    user: sent.user,
                    reply_to_message: sent.reply_to_message,
                    topic: sent.topic)
    expect(new_one).to be_valid
    expect { new_one.save! }.not_to raise_error
  end

  it 'scopes idle, sending, and sent' do
    a = create(:outgoing_draft, status: 'idle')
    b = create(:outgoing_draft, status: 'sending', sending_started_at: 1.minute.ago)
    c = create(:outgoing_draft, status: 'sent', sent_at: 1.minute.ago)
    expect(OutgoingDraft.idle).to contain_exactly(a)
    expect(OutgoingDraft.sending).to contain_exactly(b)
    expect(OutgoingDraft.sent).to contain_exactly(c)
  end

  it 'flags stale sending rows' do
    fresh = create(:outgoing_draft, status: 'sending', sending_started_at: 1.minute.ago)
    stale = create(:outgoing_draft, status: 'sending', sending_started_at: 1.hour.ago)
    expect(OutgoingDraft.stale_sending).to contain_exactly(stale)
  end

  it 'is readonly once sent' do
    draft = create(:outgoing_draft, status: 'sent', sent_at: Time.current)
    expect(draft.readonly?).to be true
    expect { draft.update!(body: 'change') }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it 'flags sent?' do
    expect(build(:outgoing_draft, status: 'sent').sent?).to be true
    expect(build(:outgoing_draft, status: 'idle').sent?).to be false
  end
end
