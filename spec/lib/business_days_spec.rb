# frozen_string_literal: true

require "rails_helper"

RSpec.describe BusinessDays do
  describe ".between" do
    it "returns 0 for a same-day response" do
      monday = Time.zone.parse("2026-07-20 09:00")
      expect(described_class.between(monday, monday + 3.hours)).to eq(0)
    end

    it "returns 1 for a response the next weekday" do
      monday = Time.zone.parse("2026-07-20 09:00")
      tuesday = Time.zone.parse("2026-07-21 09:00")
      expect(described_class.between(monday, tuesday)).to eq(1)
    end

    it "counts a Friday-to-Monday response as 1 business day, skipping the weekend" do
      friday = Time.zone.parse("2026-07-24 09:00")
      monday = Time.zone.parse("2026-07-27 09:00")
      expect(described_class.between(friday, monday)).to eq(1)
    end

    it "skips multiple weekends when spanning several weeks" do
      start_monday = Time.zone.parse("2026-07-20 09:00")
      two_weeks_later = Time.zone.parse("2026-08-03 09:00")
      expect(described_class.between(start_monday, two_weeks_later)).to eq(10)
    end

    it "returns 0 when end_time is before start_time" do
      monday = Time.zone.parse("2026-07-20 09:00")
      expect(described_class.between(monday, monday - 1.day)).to eq(0)
    end
  end
end
