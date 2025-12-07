FactoryBot.define do
  factory :team do
    sequence(:name) { |n| "team#{n}" }
    created_at { Time.current }
    updated_at { Time.current }
  end
end
