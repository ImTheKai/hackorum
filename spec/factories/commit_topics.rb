FactoryBot.define do
  factory :commit_topic do
    commit
    topic
    sequence(:external_message_id) { |n| "discussion-#{n}@example.com" }
  end
end
