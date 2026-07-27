FactoryBot.define do
  factory :patch_submission_file do
    message
    sequence(:path) { |n| "src/backend/file#{n}.c" }
  end
end
