# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ProfileHelper do
  describe "#profile_duration_label" do
    it "has no label without a duration" do
      expect(helper.profile_duration_label(nil)).to be_nil
    end

    it "collapses sub-day durations" do
      expect(helper.profile_duration_label(0.4)).to eq("under a day")
    end

    it "uses days below two months" do
      expect(helper.profile_duration_label(1.0)).to eq("1 day")
      expect(helper.profile_duration_label(45.2)).to eq("45 days")
    end

    it "uses months instead of a large day count" do
      expect(helper.profile_duration_label(60.0)).to eq("2 months")
      expect(helper.profile_duration_label(400.0)).to eq("13 months")
    end

    it "uses years past a year and a half, dropping a zero decimal" do
      expect(helper.profile_duration_label(548.0)).to eq("1.5 years")
      expect(helper.profile_duration_label(730.5)).to eq("2 years")
      expect(helper.profile_duration_label(5971.85)).to eq("16.4 years")
    end
  end

  describe "#profile_thread_showcases" do
    let(:long)    { instance_double(Topic, id: 1, title: "Long one") }
    let(:crowded) { instance_double(Topic, id: 2, title: "Crowded one", participant_count: 12) }
    let(:chatty)  { instance_double(Topic, id: 3, title: "Chatty one", message_count: 40) }

    def stats(longest:, most_participants:, most_messages:, days: 100.0)
      instance_double(ProfileStats,
                      longest_running_thread: longest,
                      longest_running_thread_days: days,
                      most_participants_thread: most_participants,
                      most_messages_thread: most_messages)
    end

    it "lists one row per superlative when three threads win" do
      showcases = helper.profile_thread_showcases(
        stats(longest: long, most_participants: crowded, most_messages: chatty)
      )

      expect(showcases.map { |s| s[:label] })
        .to eq([ "Longest running", "Most participants", "Most messages" ])
      expect(showcases.map { |s| s[:topic].title })
        .to eq([ "Long one", "Crowded one", "Chatty one" ])
      expect(showcases.map { |s| s[:meta] })
        .to eq([ "3 months", "12 participants", "40 messages" ])
    end

    it "merges the labels rather than dropping a superlative when one thread wins several" do
      winner = instance_double(Topic, id: 4, title: "Winner", participant_count: 12, message_count: 40)

      showcases = helper.profile_thread_showcases(
        stats(longest: winner, most_participants: winner, most_messages: winner, days: 10.0)
      )

      expect(showcases.size).to eq(1)
      expect(showcases.first[:label]).to eq("Longest running + most participants + most messages")
      expect(showcases.first[:meta]).to eq("10 days - 12 participants - 40 messages")
    end

    it "keeps the distinct thread when only two superlatives collide" do
      shared = instance_double(Topic, id: 5, title: "Shared", participant_count: 12, message_count: 40)

      showcases = helper.profile_thread_showcases(
        stats(longest: long, most_participants: shared, most_messages: shared)
      )

      expect(showcases.map { |s| s[:label] })
        .to eq([ "Longest running", "Most participants + most messages" ])
    end

    it "has nothing to show without threads" do
      expect(helper.profile_thread_showcases(
        stats(longest: nil, most_participants: nil, most_messages: nil, days: nil)
      )).to be_empty
    end
  end
end
