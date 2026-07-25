# frozen_string_literal: true

# Builds the week grid the contribution calendar partial renders from a
# { Date => count } hash. The grid spans whole weeks, so it reaches a few days
# into the neighbouring years - callers must supply counts for that whole range.
# The range always covers an exact multiple of 7 days, so every slice below is a
# full week and needs no padding.
module ContributionCalendar
  def self.build(counts, year, wday_start = WeekCalculation::DEFAULT_WEEK_START)
    year = year.to_i
    start_date, end_date = WeekCalculation.year_weeks_range(year, wday_start)

    total_days = (end_date - start_date).to_i + 1
    days = (0...total_days).map do |idx|
      date = start_date + idx
      count = counts[date] || 0
      { date: date, count: count, level: level(count) }
    end

    weeks_data = days.each_slice(7).map do |week_days|
      first_day = week_days.first[:date]
      week_num = WeekCalculation.week_number(first_day, year, wday_start)
      { days: week_days, year: year, week: week_num, count: week_days.sum { |d| d[:count] } }
    end

    [ weeks_data, month_spans(weeks_data) ]
  end

  def self.level(count)
    return 0 if count.zero?
    return 1 if count < 3
    return 2 if count < 6
    return 3 if count < 10
    4
  end

  def self.month_spans(weeks_data)
    spans = []
    current_month = nil
    current_span = 0

    weeks_data.each do |week|
      first_date = week[:days].first[:date]
      month_key = [ first_date.year, first_date.month ]
      if current_month != month_key
        spans << span_for(current_month, current_span) if current_month
        current_month = month_key
        current_span = 1
      else
        current_span += 1
      end
    end

    spans << span_for(current_month, current_span) if current_month
    spans
  end

  def self.span_for(month_key, span)
    { label: Date.new(month_key[0], month_key[1], 1).strftime("%b"), year: month_key[0], month: month_key[1], span: span }
  end
  private_class_method :span_for
end
