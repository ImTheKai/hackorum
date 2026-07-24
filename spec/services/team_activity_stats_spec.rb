# frozen_string_literal: true

require "rails_helper"

RSpec.describe TeamActivityStats do
  let(:team_alias) { create(:alias) }
  let(:other_team_alias) { create(:alias) }
  let(:external_alias) { create(:alias) }
  let(:team_person_ids) { [ team_alias.person_id, other_team_alias.person_id ] }

  let(:window_start) { 7.days.ago.beginning_of_day }
  let(:window_end) { Time.current.end_of_day }

  subject(:result) do
    described_class.new(team_person_ids: team_person_ids, window_start: window_start, window_end: window_end).call
  end

  it "returns all-zero/nil stats when the team has no members" do
    empty_result = described_class.new(team_person_ids: [], window_start: window_start, window_end: window_end).call

    expect(empty_result.new_thread_count).to eq(0)
    expect(empty_result.median_first_response_hours).to be_nil
    expect(empty_result.waiting_for_response_count).to eq(0)
  end

  it "returns all-zero/nil window stats when the team sent no messages in the window" do
    expect(result.new_thread_count).to eq(0)
    expect(result.joined_thread_count).to eq(0)
    expect(result.continuing_thread_count).to eq(0)
    expect(result.median_first_response_hours).to be_nil
  end

  describe "thread breakdown" do
    it "classifies a thread the team started in-window as new" do
      topic = create(:topic, creator_alias: team_alias, created_at: 3.days.ago)
      create(:message, topic: topic, sender: team_alias, sender_person_id: team_alias.person_id, created_at: 3.days.ago)

      expect(result.new_thread_count).to eq(1)
      expect(result.joined_thread_count).to eq(0)
      expect(result.continuing_thread_count).to eq(0)
    end

    it "classifies an externally-started thread the team first posted in this week as joined" do
      topic = create(:topic, creator_alias: external_alias, created_at: 20.days.ago)
      create(:message, topic: topic, sender: external_alias, sender_person_id: external_alias.person_id, created_at: 20.days.ago)
      create(:message, topic: topic, sender: team_alias, sender_person_id: team_alias.person_id, created_at: 3.days.ago)

      expect(result.joined_thread_count).to eq(1)
      expect(result.new_thread_count).to eq(0)
      expect(result.continuing_thread_count).to eq(0)
    end

    it "classifies a thread the team already participated in before the window as continuing" do
      topic = create(:topic, creator_alias: external_alias, created_at: 20.days.ago)
      create(:message, topic: topic, sender: external_alias, sender_person_id: external_alias.person_id, created_at: 20.days.ago)
      create(:message, topic: topic, sender: team_alias, sender_person_id: team_alias.person_id, created_at: 15.days.ago)
      create(:message, topic: topic, sender: team_alias, sender_person_id: team_alias.person_id, created_at: 2.days.ago)

      expect(result.continuing_thread_count).to eq(1)
      expect(result.joined_thread_count).to eq(0)
      expect(result.new_thread_count).to eq(0)
    end
  end

  describe "median time to first response" do
    it "computes the delta between an external thread's start and the team's first reply, in hours" do
      topic = create(:topic, creator_alias: external_alias, created_at: 4.days.ago)
      create(:message, topic: topic, sender: external_alias, sender_person_id: external_alias.person_id, created_at: 4.days.ago)
      create(:message, topic: topic, sender: team_alias, sender_person_id: team_alias.person_id, created_at: 4.days.ago + 30.hours)

      expect(result.median_first_response_hours).to eq(30.0)
      expect(result.first_response_sample_size).to eq(1)
    end
  end

  describe "backlog metrics" do
    it "counts threads waiting for a team response within the last 90 days" do
      topic = create(:topic, creator_alias: team_alias, created_at: 10.days.ago)
      create(:message, topic: topic, sender: team_alias, sender_person_id: team_alias.person_id, created_at: 10.days.ago)
      create(:message, topic: topic, sender: external_alias, sender_person_id: external_alias.person_id, created_at: 9.days.ago)

      expect(result.waiting_for_response_count).to eq(1)
    end

    it "excludes threads whose last message is older than 90 days" do
      topic = create(:topic, creator_alias: team_alias, created_at: 200.days.ago)
      create(:message, topic: topic, sender: team_alias, sender_person_id: team_alias.person_id, created_at: 200.days.ago)
      create(:message, topic: topic, sender: external_alias, sender_person_id: external_alias.person_id, created_at: 150.days.ago)

      expect(result.waiting_for_response_count).to eq(0)
    end

    it "counts patches the team introduced that are waiting for an author update" do
      topic = create(:topic, creator_alias: team_alias, created_at: 10.days.ago)
      create(:message, topic: topic, sender: team_alias, sender_person_id: team_alias.person_id,
                        created_at: 10.days.ago, is_patch_submission: true)
      create(:message, topic: topic, sender: external_alias, sender_person_id: external_alias.person_id, created_at: 9.days.ago)

      expect(result.patches_waiting_for_update_count).to eq(1)
    end

    it "does not count patches where an external contributor sent the first revision" do
      topic = create(:topic, creator_alias: external_alias, created_at: 10.days.ago)
      create(:message, topic: topic, sender: external_alias, sender_person_id: external_alias.person_id,
                        created_at: 10.days.ago, is_patch_submission: true)
      create(:message, topic: topic, sender: team_alias, sender_person_id: team_alias.person_id, created_at: 9.days.ago)

      expect(result.patches_waiting_for_update_count).to eq(0)
    end
  end

  describe "community reach" do
    it "counts unique external contributors across in-window topics" do
      topic = create(:topic, creator_alias: team_alias, created_at: 3.days.ago)
      create(:message, topic: topic, sender: team_alias, sender_person_id: team_alias.person_id, created_at: 3.days.ago)
      create(:message, topic: topic, sender: external_alias, sender_person_id: external_alias.person_id, created_at: 2.days.ago)

      expect(result.unique_external_contributor_count).to eq(1)
    end

    it "counts threads with further community engagement after the team's last in-window message" do
      topic = create(:topic, creator_alias: team_alias, created_at: 3.days.ago)
      create(:message, topic: topic, sender: team_alias, sender_person_id: team_alias.person_id, created_at: 3.days.ago)
      create(:message, topic: topic, sender: external_alias, sender_person_id: external_alias.person_id, created_at: 2.days.ago)

      expect(result.threads_with_further_engagement_count).to eq(1)
    end

    it "does not count threads where nobody replied after the team" do
      topic = create(:topic, creator_alias: team_alias, created_at: 3.days.ago)
      create(:message, topic: topic, sender: team_alias, sender_person_id: team_alias.person_id, created_at: 3.days.ago)

      expect(result.threads_with_further_engagement_count).to eq(0)
    end
  end

  describe "business-day response percentages" do
    it "reports 100% within 5 business days for a same-week reply" do
      topic = create(:topic, creator_alias: team_alias, created_at: 3.days.ago)
      create(:message, topic: topic, sender: external_alias, sender_person_id: external_alias.person_id, created_at: 3.days.ago)
      create(:message, topic: topic, sender: team_alias, sender_person_id: team_alias.person_id, created_at: 2.days.ago)

      expect(result.external_reply_response_events_count).to eq(1)
      expect(result.external_reply_pct_within_5_bdays).to eq(100.0)
    end
  end
end
