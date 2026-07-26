FactoryBot.define do
  factory :patch_ci_repo_state do
    sequence(:master_sha) { |n| n.to_s(16).rjust(40, "0") }
    master_committed_at { Time.current }
    master_commit_height { 100_000 }
    fetched_at { Time.current }
  end
end
