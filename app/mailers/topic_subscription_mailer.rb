class TopicSubscriptionMailer < ApplicationMailer
  def new_message(subscription, message)
    @subscription    = subscription
    @message         = message
    @topic           = message.topic
    @unsubscribe_url = topic_unsubscribe_url(subscription.unsubscribe_token)
    @thread_url      = topic_url(@topic)

    recipient = subscription.user.primary_alias&.email
    return unless recipient

    mail(
      to:      recipient,
      subject: "New message in: #{@topic.title}"
    )
  end
end
