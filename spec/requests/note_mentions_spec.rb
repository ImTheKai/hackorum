require "rails_helper"

RSpec.describe "NoteMentions", type: :request do
  def sign_in(email:, password: "secret")
    post session_path, params: { email: email, password: password }
    expect(response).to redirect_to(root_path)
  end

  def attach_verified_alias(user, email:, primary: true)
    al = create(:alias, user: user, email: email)
    if primary && user.person&.default_alias_id.nil?
      user.person.update!(default_alias_id: al.id)
    end
    Alias.by_email(email).update_all(verified_at: Time.current)
    al
  end

  let!(:topic) { create(:topic) }
  let!(:author) { create(:user, password: "secret", password_confirmation: "secret") }
  let!(:mentioned_user) { create(:user, password: "secret", password_confirmation: "secret") }
  let!(:other_user) { create(:user, password: "secret", password_confirmation: "secret") }
  let!(:team) { create(:team) }
  let!(:team_admin) { create(:user, password: "secret", password_confirmation: "secret") }
  let!(:team_member) { create(:user, password: "secret", password_confirmation: "secret") }

  let!(:note) { Note.create!(topic: topic, author: author, body: "A note") }
  let!(:user_mention) { NoteMention.create!(note: note, mentionable: mentioned_user) }
  let!(:team_mention) { NoteMention.create!(note: note, mentionable: team) }

  before do
    create(:team_member, team: team, user: team_admin, role: "admin")
    create(:team_member, team: team, user: team_member, role: "member")
  end

  describe "DELETE /note_mentions/:id" do
    context "when user removes their own mention" do
      before do
        attach_verified_alias(mentioned_user, email: "mentioned@example.com")
        sign_in(email: "mentioned@example.com")
      end

      it "allows the mentioned user to remove their own mention" do
        expect {
          delete note_mention_path(user_mention)
        }.to change(NoteMention, :count).by(-1)

        expect(response).to redirect_to(topic_path(topic))
        expect(flash[:notice]).to eq("Mention removed")
      end
    end

    context "when user tries to remove another user's mention" do
      before do
        attach_verified_alias(other_user, email: "other@example.com")
        sign_in(email: "other@example.com")
      end

      it "prevents removing another user's mention" do
        expect {
          delete note_mention_path(user_mention)
        }.not_to change(NoteMention, :count)

        expect(response).to redirect_to(topic_path(topic))
        expect(flash[:alert]).to eq("You can only remove your own mentions")
      end
    end

    context "when team admin removes team mention" do
      before do
        attach_verified_alias(team_admin, email: "teamadmin@example.com")
        sign_in(email: "teamadmin@example.com")
      end

      it "allows team admin to remove team mention" do
        expect {
          delete note_mention_path(team_mention)
        }.to change(NoteMention, :count).by(-1)

        expect(response).to redirect_to(topic_path(topic))
        expect(flash[:notice]).to eq("Mention removed")
      end
    end

    context "when team member (non-admin) tries to remove team mention" do
      before do
        attach_verified_alias(team_member, email: "teammember@example.com")
        sign_in(email: "teammember@example.com")
      end

      it "prevents non-admin team members from removing team mention" do
        expect {
          delete note_mention_path(team_mention)
        }.not_to change(NoteMention, :count)

        expect(response).to redirect_to(topic_path(topic))
        expect(flash[:alert]).to eq("Only team admins can remove team mentions")
      end
    end

    context "when non-team member tries to remove team mention" do
      before do
        attach_verified_alias(other_user, email: "other@example.com")
        sign_in(email: "other@example.com")
      end

      it "prevents non-members from removing team mention" do
        expect {
          delete note_mention_path(team_mention)
        }.not_to change(NoteMention, :count)

        expect(response).to redirect_to(topic_path(topic))
        expect(flash[:alert]).to eq("Only team admins can remove team mentions")
      end
    end

    context "when not signed in" do
      it "requires authentication" do
        delete note_mention_path(user_mention)

        expect(response).to redirect_to(new_session_path)
      end
    end
  end
end
