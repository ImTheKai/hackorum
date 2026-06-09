class TopicUnsubscribesController < ApplicationController
  def show
    subscription = TopicSubscription.find_by(unsubscribe_token: params[:token])
    if subscription
      @topic = subscription.topic
      subscription.destroy
    end
  end
end
