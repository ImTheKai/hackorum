module Topics
  class SubscriptionsController < ApplicationController
    before_action :require_authentication
    before_action :set_topic

    def create
      TopicSubscription.find_or_create_by!(user: current_user, topic: @topic)
      respond_to do |format|
        format.turbo_stream { render :update_subscribe_state }
        format.html { redirect_to topic_path(@topic) }
      end
    rescue ActiveRecord::RecordNotUnique
      respond_to do |format|
        format.turbo_stream { render :update_subscribe_state }
        format.html { redirect_to topic_path(@topic) }
      end
    end

    def destroy
      TopicSubscription.where(user: current_user, topic: @topic).destroy_all
      respond_to do |format|
        format.turbo_stream { render :update_subscribe_state }
        format.html { redirect_to topic_path(@topic) }
      end
    end

    private

    def set_topic
      @topic = Topic.find(params[:topic_id])
    end
  end
end
