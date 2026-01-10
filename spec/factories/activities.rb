# frozen_string_literal: true

FactoryBot.define do
  factory :activity do
    association :user
    association :subject, factory: :note
    activity_type { "note_created" }
    payload { {} }
    hidden { false }
    read_at { nil }

    trait :read do
      read_at { 1.hour.ago }
    end

    trait :hidden do
      hidden { true }
    end

    trait :for_message do
      association :subject, factory: :message
      activity_type { "topic_message_received" }
      payload do
        {
          topic_id: subject.topic_id,
          message_id: subject.id
        }
      end
    end
  end
end
