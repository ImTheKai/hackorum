FactoryBot.define do
  factory :topic_ignore do
    association :user
    association :topic
  end
end
