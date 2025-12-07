require "rails_helper"

RSpec.describe NoteBuilder do
  let(:topic) { create(:topic) }
  let(:message) { create(:message, topic: topic) }
  let(:author) { create(:user, username: "alice") }

  it "creates notes with mentions, tags, and activities" do
    mentioned_user = create(:user, username: "bob")
    team = create(:team, name: "team-two")
    team_member = create(:user, username: "carl")
    create(:team_member, team:, user: team_member)

    note = described_class.new(author: author).create!(topic:, message:, body: "Ping @bob and @team-two #Foo #bar")

    expect(note.note_tags.pluck(:tag)).to match_array(%w[foo bar])
    expect(note.note_mentions.map(&:mentionable)).to match_array([mentioned_user, team])

    activity_users = Activity.where(subject: note).pluck(:user_id)
    expect(activity_users).to include(author.id, mentioned_user.id, team_member.id)
    expect(Activity.find_by(user: author, subject: note).activity_type).to eq("note_created")
    expect(Activity.find_by(user: mentioned_user, subject: note).activity_type).to eq("note_mentioned")
  end

  it "updates mentions and hides removed recipients" do
    bob = create(:user, username: "bob")
    devs = create(:team, name: "devs")
    dev_member = create(:user, username: "dave")
    create(:team_member, team: devs, user: dev_member)
    carol = create(:user, username: "carol")

    builder = described_class.new(author: author)
    note = builder.create!(topic:, message:, body: "Hi @bob and @devs")
    builder.update!(note:, body: "Hi @bob and @carol")

    old_activity = Activity.find_by(user: dev_member, subject: note)
    new_activity = Activity.find_by(user: carol, subject: note)

    expect(old_activity.hidden).to eq(true)
    expect(new_activity).to be_present
  end
end
