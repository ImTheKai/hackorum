require "rails_helper"

RSpec.describe ProfilePeriod do
  describe ".recent" do
    it "spans the given duration up to today and reports type :recent" do
      travel_to Time.zone.local(2026, 1, 5, 12) do
        period = described_class.recent(30.days)

        expect(period.type).to eq(:recent)
        expect(period.range).to eq(Date.new(2025, 12, 6)..Date.new(2026, 1, 5))
        expect(period.to_h).to eq({ type: :recent })
      end
    end
  end

  describe ".year" do
    it "covers january to december and keeps the year in to_h" do
      period = described_class.year(2024)

      expect(period.range).to eq(Date.new(2024, 1, 1)..Date.new(2024, 12, 31))
      expect(period.year).to eq(2024)
      expect(period.to_h).to eq({ type: :year, year: 2024 })
    end

    it "accepts a string year" do
      expect(described_class.year("2019").year).to eq(2019)
    end
  end

  describe ".day" do
    it "is a single day and exposes it as :date" do
      date = Date.new(2026, 3, 14)
      period = described_class.day(date)

      expect(period.range).to eq(date..date)
      expect(period.year).to eq(2026)
      expect(period.to_h).to eq({ type: :day, date: date })
    end
  end

  describe ".week" do
    it "spans seven days from the week grid start" do
      period = described_class.week(2026, 3, WeekCalculation::DEFAULT_WEEK_START)
      start_date = WeekCalculation.week_start_date(2026, 3, WeekCalculation::DEFAULT_WEEK_START)

      expect(period.range).to eq(start_date..(start_date + 6))
      expect(period.to_h).to eq({
        type: :week, year: 2026, week: 3,
        start_date: start_date, end_date: start_date + 6
      })
    end

    it "honours a non-default week start day" do
      sunday_start = described_class.week(2026, 3, 0)

      expect(sunday_start.range.first.wday).to eq(0)
    end

    it "reaches into the previous year for week 1" do
      period = described_class.week(2026, 1, WeekCalculation::DEFAULT_WEEK_START)

      expect(period.range.first).to be < Date.new(2026, 1, 1)
      expect(period.range.count).to eq(7)
    end
  end

  describe ".month" do
    it "ends on the last day of the month" do
      period = described_class.month(2024, 2)

      expect(period.range).to eq(Date.new(2024, 2, 1)..Date.new(2024, 2, 29))
      expect(period.to_h).to eq({ type: :month, year: 2024, month: 2 })
    end
  end

  describe "#recent?" do
    it "is true only for the open-ended recent window" do
      expect(described_class.recent(30.days).recent?).to be(true)
      expect(described_class.month(2024, 2).recent?).to be(false)
    end
  end

  describe "#time_range" do
    it "widens the date range to full days" do
      period = described_class.day(Date.new(2026, 3, 14))

      expect(period.time_range.first).to eq(Date.new(2026, 3, 14).beginning_of_day)
      expect(period.time_range.last).to eq(Date.new(2026, 3, 14).end_of_day)
    end
  end
end
