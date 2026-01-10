require 'rails_helper'

RSpec.describe Alias, type: :model do
  describe '.by_email' do
    it 'matches case-insensitively and trims spaces' do
      create(:alias, email: 'User@Example.com')
      expect(Alias.by_email(' user@example.com ')).to exist
    end
  end

  describe 'auto-starring topics' do
    let(:user) { create(:user) }
    let(:guest_alias) { create(:alias, user: nil) }

    context 'when alias is linked to a user' do
      it 'stars topics where alias sent messages within the last year' do
        topic = create(:topic, updated_at: 3.months.ago)
        create(:message, topic: topic, sender: guest_alias)

        expect {
          guest_alias.update!(user: user)
        }.to change { TopicStar.count }.by(1)

        expect(TopicStar.exists?(user: user, topic: topic)).to be true
      end

      it 'does not star topics with old messages' do
        topic = create(:topic, updated_at: 13.months.ago)
        create(:message, topic: topic, sender: guest_alias, created_at: 13.months.ago)

        expect {
          guest_alias.update!(user: user)
        }.not_to change { TopicStar.count }
      end

      it 'is idempotent when topic is already starred' do
        topic = create(:topic, updated_at: 6.months.ago)
        create(:message, topic: topic, sender: guest_alias)
        TopicStar.create!(user: user, topic: topic)

        expect {
          guest_alias.update!(user: user)
        }.not_to change { TopicStar.count }
      end

      it 'stars multiple topics the alias participated in' do
        topic1 = create(:topic, updated_at: 3.months.ago)
        create(:message, topic: topic1, sender: guest_alias)

        topic2 = create(:topic, updated_at: 2.months.ago)
        create(:message, topic: topic2, sender: guest_alias)

        expect {
          guest_alias.update!(user: user)
        }.to change { TopicStar.count }.by(2)

        expect(TopicStar.exists?(user: user, topic: topic1)).to be true
        expect(TopicStar.exists?(user: user, topic: topic2)).to be true
      end

      it 'does not create stars when alias is not linked to a user' do
        topic = create(:topic, updated_at: 6.months.ago)
        create(:message, topic: topic, sender: guest_alias)

        expect {
          guest_alias.update!(name: "New Name")
        }.not_to change { TopicStar.count }
      end
    end
  end
end
