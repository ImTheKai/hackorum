FactoryBot.define do
  factory :commit do
    sequence(:sha) { |n| Digest::SHA1.hexdigest("commit-#{n}") }
    sequence(:subject) { |n| "Fix a thing in the executor (#{n})" }
    body { "" }
    authored_at { 3.days.ago }
    committed_at { 3.days.ago }
    author_name { "Alexander Lakhin" }
    author_email { "exclusion@gmail.com" }
    committer_name { "Alvaro Herrera" }
    committer_email { "alvherre@alvh.no-ip.org" }
    branches { [ "master" ] }
  end
end
