FactoryBot.define do
  factory :user_feature do
    user
    feature { "email_sending" }
  end
end
