require "rails_helper"

RSpec.describe Note, type: :model do
  let(:topic) { create(:topic) }
  let(:message) { create(:message, topic: topic) }
  let(:author) { create(:user, username: "author") }

  it "is invalid when message belongs to a different topic" do
    other_topic = create(:topic)
    note = described_class.new(topic: topic, message: create(:message, topic: other_topic), author: author, body: "oops")

    expect(note).not_to be_valid
    expect(note.errors[:message]).to include("must belong to the same topic")
  end

  it "is visible to author, mentioned users, and team members" do
    mentioned_user = create(:user, username: "bob")
    team = create(:team, name: "team-one")
    team_member = create(:user, username: "carol")
    create(:team_member, team:, user: team_member)
    outsider = create(:user, username: "outsider")

    note = described_class.create!(topic:, message:, author:, body: "hello world")
    note.note_mentions.create!(mentionable: mentioned_user)
    note.note_mentions.create!(mentionable: team)

    expect(described_class.visible_to(author)).to include(note)
    expect(described_class.visible_to(mentioned_user)).to include(note)
    expect(described_class.visible_to(team_member)).to include(note)
    expect(described_class.visible_to(outsider)).to be_empty
  end
end
