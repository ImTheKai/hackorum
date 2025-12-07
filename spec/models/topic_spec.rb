require 'rails_helper'

RSpec.describe Topic, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:creator).class_name('Alias') }
    it { is_expected.to have_many(:messages) }
    it { is_expected.to have_many(:attachments).through(:messages) }
  end

  describe "validations" do
    subject { build(:topic) }
    
    it "is valid with valid attributes" do
      expect(subject).to be_valid
    end

    it "requires a title" do
      subject.title = nil
      expect(subject).not_to be_valid
    end

    it "requires a creator" do
      subject.creator = nil
      expect(subject).not_to be_valid
    end
  end

  describe "factory" do
    it "creates a valid topic" do
      topic = create(:topic)
      expect(topic).to be_persisted
      expect(topic.title).to be_present
      expect(topic.creator).to be_present
    end

    it "creates a topic with messages" do
      topic = create(:topic, :with_messages)
      expect(topic.messages.count).to eq(3)
    end
  end
end
