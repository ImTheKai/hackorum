require 'rails_helper'

RSpec.describe TopicIgnore, type: :model do
  describe 'associations' do
    it { should belong_to(:user) }
    it { should belong_to(:topic) }
  end

  describe 'validations' do
    it 'prevents duplicate ignores' do
      user = create(:user)
      topic = create(:topic)
      create(:topic_ignore, user: user, topic: topic)

      duplicate = build(:topic_ignore, user: user, topic: topic)
      expect(duplicate).not_to be_valid
    end
  end

  describe '.toggle_ignore' do
    let(:user) { create(:user) }
    let(:topic) { create(:topic) }

    it 'creates an ignore record if none exists' do
      result = TopicIgnore.toggle_ignore(user: user, topic: topic)
      expect(result).to be true
      expect(TopicIgnore.count).to eq(1)
    end

    it 'removes an ignore record if one exists' do
      create(:topic_ignore, user: user, topic: topic)
      result = TopicIgnore.toggle_ignore(user: user, topic: topic)
      expect(result).to be false
      expect(TopicIgnore.count).to eq(0)
    end
  end

  describe '.ignored_by_user?' do
    let(:user) { create(:user) }
    let(:topic) { create(:topic) }

    it 'returns true when user has ignored the topic' do
      create(:topic_ignore, user: user, topic: topic)
      expect(TopicIgnore.ignored_by_user?(user: user, topic: topic)).to be true
    end

    it 'returns false when user has not ignored the topic' do
      expect(TopicIgnore.ignored_by_user?(user: user, topic: topic)).to be false
    end
  end
end
