require 'rails_helper'

RSpec.describe TopicUnsubscribesController, type: :request do
  let(:user)         { create(:user) }
  let(:topic)        { create(:topic) }
  let(:subscription) { create(:topic_subscription, user: user, topic: topic) }

  describe "GET /unsubscribe/:token" do
    it "destroys the subscription and renders success" do
      token = subscription.unsubscribe_token
      expect {
        get topic_unsubscribe_path(token)
      }.to change(TopicSubscription, :count).by(-1)
      expect(response).to have_http_status(:ok)
    end

    it "renders gracefully for an unknown token" do
      get topic_unsubscribe_path("invalid-token-xyz")
      expect(response).to have_http_status(:ok)
    end

    it "does not require authentication" do
      token = subscription.unsubscribe_token
      get topic_unsubscribe_path(token)
      expect(response).to have_http_status(:ok)
    end
  end
end
