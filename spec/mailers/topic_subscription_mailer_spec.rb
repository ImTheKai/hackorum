require 'rails_helper'

RSpec.describe TopicSubscriptionMailer, type: :mailer do
  let(:topic)        { create(:topic, title: "BUG: heap corruption in btree") }
  let(:user)         { create(:user) }
  let(:ali)          { create(:alias, user: user) }
  let(:subscription) { create(:topic_subscription, user: user, topic: topic) }
  let(:message)      { create(:message, topic: topic) }

  before { ali; user.reload }  # ensure primary_alias is set

  describe "#new_message" do
    subject(:mail) { TopicSubscriptionMailer.new_message(subscription, message) }

    it "sends to the user primary alias email" do
      expect(mail.to).to eq([user.primary_alias.email])
    end

    it "includes the topic title in the subject" do
      expect(mail.subject).to include(topic.title)
    end

    it "includes the thread URL in the html body" do
      expect(mail.html_part.body.to_s).to include(topic_url(topic))
    end

    it "includes the unsubscribe token in the html body" do
      expect(mail.html_part.body.to_s).to include(subscription.unsubscribe_token)
    end

    it "has a text part with the unsubscribe token" do
      expect(mail.text_part.body.to_s).to include(subscription.unsubscribe_token)
    end

    it "returns a NullMail when user has no primary alias" do
      allow(user).to receive(:primary_alias).and_return(nil)
      expect(mail.message).to be_a(Mail::NullMail)
    end
  end
end
