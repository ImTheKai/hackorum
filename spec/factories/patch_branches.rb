FactoryBot.define do
  factory :patch_branch do
    topic
    message { association(:message, topic: topic) }
    sequence(:branch_name) { |n| "t#{n}_1" }
    status { "applied" }
    on_master { true }
    attempted_at { Time.current }
  end
end
