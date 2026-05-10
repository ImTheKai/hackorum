require 'rails_helper'

RSpec.describe OAuth::TokenRefresher do
  let(:identity) {
    create(:identity, refresh_token: 'r1', access_token: nil,
                      access_token_expires_at: nil)
  }

  def stub_post_form(body:, code: '200')
    res = double('Net::HTTPResponse', body: body, code: code)
    allow(Net::HTTP).to receive(:post_form).and_return(res)
    res
  end

  it 'no-ops when access_token is fresh' do
    identity.update!(access_token: 'a',
                     access_token_expires_at: 5.minutes.from_now)
    expect(Net::HTTP).not_to receive(:post_form)
    described_class.call(identity)
  end

  it 'refreshes when access_token is stale' do
    stub_post_form(body: { access_token: 'newA', expires_in: 3600 }.to_json,
                   code: '200')
    described_class.call(identity)
    identity.reload
    expect(identity.access_token).to eq('newA')
    expect(identity.access_token_expires_at).to be_within(2.seconds).of(1.hour.from_now)
  end

  it 'raises AuthRevokedError on 4xx and revokes locally' do
    stub_post_form(body: '{"error":"invalid_grant"}', code: '400')
    expect { described_class.call(identity) }.to raise_error(Gmail::AuthRevokedError)
    identity.reload
    expect(identity.send_revoked_at).not_to be_nil
    expect(identity.refresh_token).to be_nil
    expect(identity.access_token).to be_nil
    expect(identity.last_send_error).to be_present
  end

  it 'raises TransientError on 5xx' do
    stub_post_form(body: 'down', code: '503')
    expect { described_class.call(identity) }.to raise_error(Gmail::TransientError)
    expect(identity.reload.send_revoked_at).to be_nil
  end

  it 'raises TransientError when 200 body lacks access_token' do
    stub_post_form(body: '{"expires_in":3600}', code: '200')
    expect { described_class.call(identity) }.to raise_error(Gmail::TransientError)
    expect(identity.reload.access_token).to be_nil  # not poisoned
  end
end
