FactoryBot.define do
  factory :identity do
    user
    provider { 'google_oauth2' }
    sequence(:uid)   { |n| "uid-#{n}" }
    sequence(:email) { |n| "id-#{n}@example.com" }
  end
end
