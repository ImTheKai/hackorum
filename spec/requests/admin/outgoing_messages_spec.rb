require 'rails_helper'

RSpec.describe 'Admin::OutgoingMessages', type: :request do
  let(:admin) { create(:user, admin: true) }

  before do
    sign_in_as(admin)
    allow_any_instance_of(ApplicationController).to receive(:current_admin?).and_return(true)
  end

  describe 'GET /admin/outgoing_messages' do
    let(:topic)    { create(:topic) }
    let(:identity) { create(:identity, refresh_token: 'r') }

    it 'lists pending and recent sent messages' do
      pending_msg = create(:message, topic: topic, state: 'pending',
                                     sent_at: 5.minutes.ago,
                                     sent_via_identity_id: identity.id,
                                     sent_to_address: 'list@x')
      recent = create(:message, topic: topic, state: 'sent',
                                sent_at: 1.minute.ago,
                                sent_via_identity_id: identity.id,
                                sent_to_address: 'list@x')

      get '/admin/outgoing_messages'
      expect(response).to be_successful
      expect(response.body).to include('Pending')
      expect(response.body).to include('Recently sent')
      expect(response.body).to include(pending_msg.subject)
      expect(response.body).to include(recent.subject)
    end

    it 'requires admin' do
      allow_any_instance_of(ApplicationController).to receive(:current_admin?).and_return(false)
      get '/admin/outgoing_messages'
      expect(response).to redirect_to(root_path)
    end
  end
end
