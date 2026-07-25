FactoryBot.define do
  factory :release_tag do
    sequence(:name) { |n| "REL_18_#{n}" }
    version { ReleaseTag.normalize(name) }
    released_at { 1.month.ago }
    sequence(:commit_sha) { |n| Digest::SHA1.hexdigest("tag-#{n}") }
  end
end
