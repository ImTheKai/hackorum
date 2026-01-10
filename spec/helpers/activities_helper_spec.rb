# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ActivitiesHelper do
  describe "#activity_type_label" do
    it "returns sender name for topic_message_received with Message subject" do
      sender = create(:alias, name: "John Doe")
      message = create(:message, sender: sender)
      activity = create(:activity, :for_message, subject: message)

      expect(helper.activity_type_label(activity)).to eq("New message from John Doe")
    end

    it "returns generic label for topic_message_received without Message subject" do
      subject = double("Subject")
      activity = double("Activity", activity_type: "topic_message_received", subject: subject)

      expect(helper.activity_type_label(activity)).to eq("Topic message received")
    end

    it "returns humanized activity type for note_created" do
      activity = double("Activity", activity_type: "note_created")

      expect(helper.activity_type_label(activity)).to eq("Note created")
    end

    it "returns humanized activity type for note_mentioned" do
      activity = double("Activity", activity_type: "note_mentioned")

      expect(helper.activity_type_label(activity)).to eq("Note mentioned")
    end
  end
end
