FactoryBot.define do
  factory :commit_person do
    commit
    person
    role { "author" }
    raw_name { "Alexander Lakhin" }
    raw_email { "exclusion@gmail.com" }
  end
end
