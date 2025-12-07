FactoryBot.define do
  factory :topic do
    sequence(:title) { |n| "PostgreSQL Feature Discussion #{n}" }
    creator factory: :alias
    created_at { 1.week.ago }
    updated_at { 1.week.ago }

    trait :recent do
      created_at { 1.day.ago }
      updated_at { 1.day.ago }
    end

    trait :old do
      created_at { 6.months.ago }
      updated_at { 6.months.ago }
    end

    trait :with_messages do
      after(:create) do |topic|
        create_list(:message, 3, topic: topic, sender: topic.creator)
      end
    end
  end
end