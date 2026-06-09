FactoryBot.define do
  factory :topic_subscription do
    association :user
    association :topic
  end
end
