require 'rails_helper'

RSpec.describe Outgoing::MessageBuilder do
  let(:user)     { create(:user) }
  let(:identity) { create(:identity, user: user, email: 'a@b', refresh_token: 'r') }
  let(:sender)   { create(:alias, user: user, name: 'Alice', email: 'a@b') }
  let(:list)     { create(:mailing_list, post_address: 'list@example.com') }
  let(:topic)    { create(:topic, mailing_lists: [list]) }
  let(:parent) {
    create(:message, topic: topic, message_id: '<parent-id@x>',
           mailing_lists: [list])
  }

  before do
    allow(Outgoing::RecipientResolver).to receive(:for)
      .with(topic).and_return('test@example.com')
  end

  def build_draft(overrides = {})
    create(:outgoing_draft,
           {user: user, topic: topic, reply_to_message: parent,
            sender_alias: sender, identity: identity,
            subject: 'Re: hello', body: 'hi'}.merge(overrides))
  end

  it 'builds RFC822 with proper From, To, Subject, Body' do
    with_env('HACKORUM_OUTGOING_DOMAIN' => 'hackorum.local') do
      result = described_class.build(build_draft)
      mail = Mail.new(result.encoded)
      expect(mail.from).to include('a@b')
      expect(mail.to).to eq(['test@example.com'])
      expect(mail.subject).to eq('Re: hello')
      expect(mail.body.to_s.strip).to eq('hi')
    end
  end

  it 'sets Message-Id with the configured outgoing domain' do
    with_env('HACKORUM_OUTGOING_DOMAIN' => 'hackorum.local') do
      result = described_class.build(build_draft)
      expect(result.message_id).to match(/\A<[0-9a-f-]{36}@hackorum.local>\z/)
      expect(Mail.new(result.encoded).message_id).to eq(result.message_id.gsub(/[<>]/, ''))
    end
  end

  it 'falls back to default outgoing domain when env unset' do
    with_env('HACKORUM_OUTGOING_DOMAIN' => nil) do
      result = described_class.build(build_draft)
      expect(result.message_id).to end_with('@hackorum.local>')
    end
  end

  it 'sets In-Reply-To to parent message_id' do
    with_env('HACKORUM_OUTGOING_DOMAIN' => 'hackorum.local') do
      result = described_class.build(build_draft)
      mail = Mail.new(result.encoded)
      expect(mail.in_reply_to).to eq('parent-id@x')
    end
  end

  it 'walks the reply chain to build References' do
    grand = create(:message, topic: topic, message_id: '<grand@x>')
    parent.update!(reply_to: grand, reply_to_message_id: '<grand@x>')
    with_env('HACKORUM_OUTGOING_DOMAIN' => 'hackorum.local') do
      result = described_class.build(build_draft)
      mail = Mail.new(result.encoded)
      refs = mail.references
      refs = [refs] unless refs.is_a?(Array)
      expect(refs).to include('grand@x', 'parent-id@x')
    end
  end

  it 'omits ancestors with nil message_id from References' do
    orphan = create(:message, topic: topic, message_id: nil)
    parent.update!(reply_to: orphan, reply_to_message_id: nil)
    with_env('HACKORUM_OUTGOING_DOMAIN' => 'hackorum.local') do
      result = described_class.build(build_draft)
      refs = Mail.new(result.encoded).references
      refs = [refs] unless refs.is_a?(Array)
      expect(refs).to contain_exactly('parent-id@x')
    end
  end

  it 'returns the resolver result as recipient' do
    with_env('HACKORUM_OUTGOING_DOMAIN' => 'hackorum.local') do
      result = described_class.build(build_draft)
      expect(result.recipient).to eq('test@example.com')
    end
  end

  it 'sets text/plain content type' do
    with_env('HACKORUM_OUTGOING_DOMAIN' => 'hackorum.local') do
      result = described_class.build(build_draft)
      mail = Mail.new(result.encoded)
      expect(mail.content_type).to start_with('text/plain')
      expect(mail.content_type).to include('charset=UTF-8') | include('charset=utf-8')
    end
  end
end
