require 'rails_helper'

RSpec.describe TopicSubscription, type: :model do
  it "generates an unsubscribe_token on create" do
    sub = create(:topic_subscription)
    expect(sub.unsubscribe_token).to be_present
  end

  it "enforces uniqueness per user and topic" do
    sub = create(:topic_subscription)
    expect { create(:topic_subscription, user: sub.user, topic: sub.topic) }
      .to raise_error(ActiveRecord::RecordInvalid, /already been taken/)
  end

  it "belongs to a user" do
    sub = create(:topic_subscription)
    expect(sub.user).to be_a(User)
  end

  it "belongs to a topic" do
    sub = create(:topic_subscription)
    expect(sub.topic).to be_a(Topic)
  end
end
