require 'rails_helper'

RSpec.describe Topics::SubscriptionsController, type: :request do
  let(:user)  { create(:user) }
  let(:topic) { create(:topic) }

  describe "POST /topics/:topic_id/subscription" do
    context "when signed in" do
      before { sign_in_as(user) }

      it "creates a subscription" do
        expect {
          post topic_subscription_path(topic)
        }.to change(TopicSubscription, :count).by(1)
        expect(response).to have_http_status(:found)
      end

      it "is idempotent (no duplicate on double-post)" do
        create(:topic_subscription, user: user, topic: topic)
        expect {
          post topic_subscription_path(topic)
        }.not_to change(TopicSubscription, :count)
        expect(response).to have_http_status(:found)
      end

      it "returns turbo_stream when requested" do
        post topic_subscription_path(topic),
             headers: { "Accept" => "text/vnd.turbo-stream.html" }
        expect(response.media_type).to eq(Mime[:turbo_stream].to_s)
      end
    end

    context "when not signed in" do
      it "redirects to sign in" do
        post topic_subscription_path(topic)
        expect(response).to redirect_to(new_session_path)
      end
    end
  end

  describe "DELETE /topics/:topic_id/subscription" do
    context "when signed in" do
      before { sign_in_as(user) }

      let!(:subscription) { create(:topic_subscription, user: user, topic: topic) }

      it "destroys the subscription" do
        expect {
          delete topic_subscription_path(topic)
        }.to change(TopicSubscription, :count).by(-1)
        expect(response).to have_http_status(:found)
      end

      it "returns turbo_stream when requested" do
        delete topic_subscription_path(topic),
               headers: { "Accept" => "text/vnd.turbo-stream.html" }
        expect(response.media_type).to eq(Mime[:turbo_stream].to_s)
      end
    end

    context "when not signed in" do
      it "redirects to sign in" do
        delete topic_subscription_path(topic)
        expect(response).to redirect_to(new_session_path)
      end
    end
  end
end
