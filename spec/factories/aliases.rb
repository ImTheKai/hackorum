FactoryBot.define do
  factory :alias do
    user { nil }  # Can be anonymous
    person { user&.person || association(:person) }
    sequence(:name) { |n| "User #{n}" }
    sequence(:email) { |n| "user#{n}@postgresql.org" }
    primary_alias { false }
    sender_count { 0 }
    created_at { 1.month.ago }
    updated_at { 1.month.ago }

    after(:create) do |alias_record|
      if alias_record.person && alias_record.person.default_alias_id.nil?
        alias_record.person.update!(default_alias_id: alias_record.id)
      end
    end

    trait :with_user do
      user
    end

    trait :primary do
      primary_alias { true }
    end

    trait :anonymous do
      user { nil }
    end

    trait :with_sent_messages do
      sender_count { 5 }
    end

    trait :mention_only do
      sender_count { 0 }
    end
  end
end
