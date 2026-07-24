# frozen_string_literal: true

require "rails_helper"

RSpec.describe Team, type: :model do
  let(:user) { create(:user) }
  let(:user2) { create(:user) }
  let(:team) { Team.create!(name: "Team1") }

  before do
    TeamMember.add_member(team: team, user: user, role: :admin)
  end

  it "detects members and admins" do
    expect(team.member?(user)).to be(true)
    expect(team.admin?(user)).to be(true)
    expect(team.member?(user2)).to be(false)
  end

  describe "visibility" do
    it "defaults to private" do
      expect(team.visibility).to eq("private")
      expect(team.visibility_private?).to be(true)
    end

    it "can be set to visible or open" do
      team.update!(visibility: :visible)
      expect(team.visibility_visible?).to be(true)

      team.update!(visibility: :open)
      expect(team.visibility_open?).to be(true)
    end
  end

  describe "#accessible_to?" do
    it "allows members to access private teams" do
      expect(team.accessible_to?(user)).to be(true)
      expect(team.accessible_to?(user2)).to be(false)
    end

    it "allows anyone to access visible teams" do
      team.update!(visibility: :visible)
      expect(team.accessible_to?(user)).to be(true)
      expect(team.accessible_to?(user2)).to be(true)
      expect(team.accessible_to?(nil)).to be(true)
    end

    it "allows anyone to access open teams" do
      team.update!(visibility: :open)
      expect(team.accessible_to?(user)).to be(true)
      expect(team.accessible_to?(user2)).to be(true)
      expect(team.accessible_to?(nil)).to be(true)
    end
  end

  describe "name reservation" do
    it "rejects name already reserved by a user" do
      create(:user, username: "claimed")

      new_team = Team.new(name: "claimed")
      expect(new_team).not_to be_valid
      expect(new_team.errors[:name]).to include("is already taken")
    end

    it "rejects name already reserved by another team" do
      Team.create!(name: "existing")

      new_team = Team.new(name: "existing")
      expect(new_team).not_to be_valid
      expect(new_team.errors[:name]).to include("is already taken")
    end

    it "rejects name case-insensitively" do
      create(:user, username: "CaseName")

      new_team = Team.new(name: "casename")
      expect(new_team).not_to be_valid
      expect(new_team.errors[:name]).to include("is already taken")
    end

    it "creates a reservation on create" do
      new_team = Team.create!(name: "freshteam")
      reservation = NameReservation.find_by(name: "freshteam")
      expect(reservation).to be_present
      expect(reservation.owner_type).to eq("Team")
      expect(reservation.owner_id).to eq(new_team.id)
    end

    it "releases reservation on destroy" do
      new_team = Team.create!(name: "doomed")
      expect(NameReservation.find_by(name: "doomed")).to be_present

      new_team.destroy!
      expect(NameReservation.find_by(name: "doomed")).to be_nil
    end
  end

  describe "week_start_day" do
    it "defaults to Monday" do
      expect(team.week_start_day).to eq(1)
    end

    it "accepts any day 0..6" do
      team.week_start_day = 0
      expect(team).to be_valid

      team.week_start_day = 6
      expect(team).to be_valid
    end

    it "rejects values outside 0..6" do
      team.week_start_day = 7
      expect(team).not_to be_valid
      expect(team.errors[:week_start_day]).to be_present
    end
  end

  describe "#mentionable_by?" do
    it "allows only members to mention private teams" do
      expect(team.mentionable_by?(user)).to be(true)
      expect(team.mentionable_by?(user2)).to be(false)
    end

    it "allows only members to mention visible teams" do
      team.update!(visibility: :visible)
      expect(team.mentionable_by?(user)).to be(true)
      expect(team.mentionable_by?(user2)).to be(false)
    end

    it "allows anyone to mention open teams" do
      team.update!(visibility: :open)
      expect(team.mentionable_by?(user)).to be(true)
      expect(team.mentionable_by?(user2)).to be(true)
    end
  end
end
