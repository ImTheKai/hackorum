# frozen_string_literal: true

module Settings
  class SubscriptionsController < Settings::BaseController
    before_action :set_subscription, only: [:destroy]

    def index
      @subscriptions = current_user.topic_subscriptions
                                   .includes(:topic)
                                   .order("topics.updated_at DESC")
    end

    def destroy
      @subscription.destroy
      redirect_to settings_subscriptions_path, notice: "Unsubscribed from thread."
    end

    def destroy_all
      current_user.topic_subscriptions.destroy_all
      redirect_to settings_subscriptions_path, notice: "Unsubscribed from all threads."
    end

    def batch_destroy
      ids = Array(params[:subscription_ids]).map(&:to_i).reject(&:zero?)
      current_user.topic_subscriptions.where(id: ids).destroy_all
      redirect_to settings_subscriptions_path, notice: "Unsubscribed from selected threads."
    end

    private

    def active_settings_section
      :subscriptions
    end

    def set_subscription
      @subscription = current_user.topic_subscriptions.find(params[:id])
    end
  end
end
