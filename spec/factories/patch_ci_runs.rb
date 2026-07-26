FactoryBot.define do
  factory :patch_ci_run do
    patch_branch
    sequence(:github_run_id) { |n| 1_000_000 + n }
    run_attempt { 1 }
    status { "success" }
    pg_major { 20 }
  end
end
