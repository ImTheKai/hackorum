require "rails_helper"

RSpec.describe ContributionCalendar do
  def all_days(weeks)
    weeks.flat_map { |week| week[:days] }
  end

  describe ".build" do
    it "returns weeks of seven contiguous days" do
      [ WeekCalculation::DEFAULT_WEEK_START, 0 ].each do |wday_start|
        weeks, = described_class.build({}, 2025, wday_start)

        expect(weeks).to be_present
        expect(weeks.map { |week| week[:days].length }.uniq).to eq([ 7 ])

        dates = all_days(weeks).map { |day| day[:date] }
        expect(dates).to eq((dates.first..dates.last).to_a)
      end
    end

    it "spans whole weeks, so the grid reaches outside the calendar year" do
      [ WeekCalculation::DEFAULT_WEEK_START, 0 ].each do |wday_start|
        weeks, = described_class.build({}, 2025, wday_start)
        days = all_days(weeks)

        expect(days.first[:date].wday).to eq(wday_start)
        expect(days.first[:date]).to be <= Date.new(2025, 1, 1)
        expect(days.last[:date]).to be >= Date.new(2025, 12, 31)
      end
    end

    it "numbers weeks from one and tags them with the requested year" do
      weeks, = described_class.build({}, 2025)

      expect(weeks.map { |week| week[:week] }).to eq((1..weeks.length).to_a)
      expect(weeks.map { |week| week[:year] }.uniq).to eq([ 2025 ])
    end

    it "accepts a string year" do
      weeks, = described_class.build({}, "2025")

      expect(weeks.first[:year]).to eq(2025)
    end

    it "places counts on their own dates and leaves every other day at zero" do
      counts = { Date.new(2025, 3, 14) => 4, Date.new(2025, 7, 1) => 12 }
      weeks, = described_class.build(counts, 2025)
      days = all_days(weeks)

      expect(days.find { |day| day[:date] == Date.new(2025, 3, 14) }).to include(count: 4, level: 2)
      expect(days.find { |day| day[:date] == Date.new(2025, 7, 1) }).to include(count: 12, level: 4)

      rest = days.reject { |day| counts.key?(day[:date]) }
      expect(rest.map { |day| day[:count] }.uniq).to eq([ 0 ])
      expect(rest.map { |day| day[:level] }.uniq).to eq([ 0 ])
    end

    it "totals each week's counts" do
      counts = { Date.new(2025, 3, 10) => 2, Date.new(2025, 3, 12) => 3 }
      weeks, = described_class.build(counts, 2025)
      week = weeks.find { |w| w[:days].any? { |day| day[:date] == Date.new(2025, 3, 10) } }

      expect(week[:count]).to eq(5)
      expect(weeks.sum { |w| w[:count] }).to eq(5)
    end
  end

  describe ".level" do
    it "buckets counts at every boundary" do
      expected = { 0 => 0, 1 => 1, 2 => 1, 3 => 2, 5 => 2, 6 => 3, 9 => 3, 10 => 4, 11 => 4 }
      actual = expected.keys.to_h { |count| [ count, described_class.level(count) ] }

      expect(actual).to eq(expected)
    end
  end

  describe "month spans" do
    it "sums to the number of weeks and labels months by abbreviated name" do
      weeks, spans = described_class.build({}, 2025)

      expect(spans.sum { |span| span[:span] }).to eq(weeks.length)
      spans.each do |span|
        expect(span[:label]).to eq(Date.new(span[:year], span[:month], 1).strftime("%b"))
      end
      expect(spans.map { |span| span[:label] }).to include("Jan", "Jun", "Dec")
    end

    it "closes a span when a week's first day crosses into a new month" do
      weeks, spans = described_class.build({}, 2025)

      months = weeks.map do |week|
        first_date = week[:days].first[:date]
        [ first_date.year, first_date.month ]
      end
      expected = months.chunk_while { |a, b| a == b }.map do |run|
        { label: Date.new(run.first[0], run.first[1], 1).strftime("%b"), year: run.first[0], month: run.first[1], span: run.length }
      end

      expect(spans).to eq(expected)
    end

    it "opens the grid in the previous year when the first week starts there" do
      _weeks, spans = described_class.build({}, 2025)

      expect(spans.first).to eq({ label: "Dec", year: 2024, month: 12, span: 1 })
    end
  end
end
