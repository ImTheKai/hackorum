# frozen_string_literal: true

module ActivitiesHelper
  def activity_type_label(activity)
    case activity.activity_type
    when "topic_message_received"
      subject = activity.subject
      if subject.is_a?(Message)
        "New message from #{subject.sender.name}"
      else
        "Topic message received"
      end
    else
      activity.activity_type.humanize
    end
  end
end
