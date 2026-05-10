FactoryBot.define do
  factory :outgoing_draft do
    user
    topic
    reply_to_message { create(:message, topic: topic) }
    sender_alias    { create(:alias, user: user) }
    identity        { create(:identity, user: user, refresh_token: 'r') }
    sequence(:subject) { |n| "Re: subject #{n}" }
    body { "" }
    status { "idle" }
  end
end
