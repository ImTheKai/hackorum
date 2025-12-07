FactoryBot.define do
  factory :mention do
    message
    association :alias
    created_at { 1.week.ago }
    updated_at { 1.week.ago }
  end
end