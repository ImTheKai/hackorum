FactoryBot.define do
  factory :admin_email_change do
    association :performed_by, factory: :user
    association :target_user, factory: :user
    email { Faker::Internet.email }
    aliases_attached { 0 }
    created_new_alias { true }
  end
end
