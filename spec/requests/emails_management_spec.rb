require 'rails_helper'

RSpec.describe 'Emails management', type: :request do
  include ActiveJob::TestHelper

  before { clear_enqueued_jobs && ActionMailer::Base.deliveries.clear }

  def sign_in(email:, password: 'secret')
    post session_path, params: { email: email, password: password }
    expect(response).to redirect_to(root_path)
  end

  it 'sends verification for adding a new email and attaches on verify' do
    user = create(:user, password: 'secret', password_confirmation: 'secret')
    create(:alias, user: user, email: 'me@example.com', primary_alias: true)
    Alias.by_email('me@example.com').update_all(verified_at: Time.current)

    sign_in(email: 'me@example.com')

    perform_enqueued_jobs do
      post emails_path, params: { email: 'new-address@example.com' }
      expect(response).to redirect_to(settings_path)
    end

    raw = extract_raw_token_from_mailer
    get verification_path(token: raw)
    expect(response).to redirect_to(settings_path)

    expect(Alias.by_email('new-address@example.com').where(user_id: user.id)).to exist
  end

  it 'blocks adding an email owned by another user' do
    other = create(:user)
    create(:alias, user: other, email: 'taken@example.com', primary_alias: true)
    Alias.by_email('taken@example.com').update_all(verified_at: Time.current)

    user = create(:user, password: 'secret', password_confirmation: 'secret')
    create(:alias, user: user, email: 'me2@example.com', primary_alias: true)
    Alias.by_email('me2@example.com').update_all(verified_at: Time.current)

    sign_in(email: 'me2@example.com')
    expect {
      post emails_path, params: { email: 'taken@example.com' }
    }.not_to change { UserToken.count }
    expect(response).to redirect_to(settings_path)
  end

  def extract_raw_token_from_mailer
    mail = ActionMailer::Base.deliveries.last
    expect(mail).to be_present
    url = mail.body.encoded[%r{https?://[^\s]+}]
    Rack::Utils.parse_query(URI.parse(url).query)['token']
  end
end
