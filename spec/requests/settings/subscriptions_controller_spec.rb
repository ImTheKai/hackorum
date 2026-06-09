# frozen_string_literal: true

require "rails_helper"

RSpec.describe Settings::SubscriptionsController, type: :request do
  let(:user)  { create(:user) }
  let(:topic) { create(:topic) }

  describe "GET /settings/subscriptions" do
    context "when signed in" do
      before { sign_in_as(user) }

      it "renders the subscriptions list" do
        create(:topic_subscription, user: user, topic: topic)
        get settings_subscriptions_path
        expect(response).to have_http_status(:ok)
      end
    end

    context "when not signed in" do
      it "requires authentication" do
        get settings_subscriptions_path
        expect(response).to redirect_to(new_session_path)
      end
    end
  end

  describe "DELETE /settings/subscriptions/:id" do
    context "when signed in" do
      before { sign_in_as(user) }

      let!(:subscription) { create(:topic_subscription, user: user, topic: topic) }

      it "destroys the subscription" do
        expect {
          delete settings_subscription_path(subscription)
        }.to change(TopicSubscription, :count).by(-1)
        expect(response).to redirect_to(settings_subscriptions_path)
      end

      it "cannot destroy another user's subscription" do
        other_sub = create(:topic_subscription)
        expect {
          delete settings_subscription_path(other_sub)
        }.not_to change(TopicSubscription, :count)
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "DELETE /settings/subscriptions/destroy_all" do
    context "when signed in" do
      before { sign_in_as(user) }
      before { create_list(:topic_subscription, 3, user: user) }

      it "destroys all of the current user's subscriptions" do
        expect {
          delete destroy_all_settings_subscriptions_path
        }.to change(TopicSubscription, :count).by(-3)
        expect(response).to redirect_to(settings_subscriptions_path)
      end
    end
  end

  describe "POST /settings/subscriptions/batch_destroy" do
    context "when signed in" do
      before { sign_in_as(user) }

      let!(:subs) { create_list(:topic_subscription, 3, user: user) }

      it "destroys only the selected subscriptions" do
        ids = subs.first(2).map(&:id)
        expect {
          post batch_destroy_settings_subscriptions_path, params: { subscription_ids: ids }
        }.to change(TopicSubscription, :count).by(-2)
        expect(response).to redirect_to(settings_subscriptions_path)
      end

      it "ignores IDs belonging to other users" do
        other_sub = create(:topic_subscription)
        expect {
          post batch_destroy_settings_subscriptions_path,
               params: { subscription_ids: [other_sub.id] }
        }.not_to change(TopicSubscription, :count)
      end
    end
  end
end
