FactoryBot.define do
  factory :team_member do
    team
    user
    role { "member" }
  end
end
