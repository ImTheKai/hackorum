# frozen_string_literal: true

# The time window a profile activity view is showing. #to_h keeps the exact
# shape the views and ProfileHelper read.
class ProfilePeriod
  attr_reader :type, :year, :month, :week, :date, :start_date, :end_date

  def self.recent(duration)
    new(type: :recent, start_date: duration.ago.to_date, end_date: Date.current)
  end

  def self.year(year)
    year = year.to_i
    new(type: :year, year: year, start_date: Date.new(year, 1, 1), end_date: Date.new(year, 12, 31))
  end

  def self.day(date)
    new(type: :day, date: date, year: date.year, start_date: date, end_date: date)
  end

  def self.week(year, week, wday_start = WeekCalculation::DEFAULT_WEEK_START)
    year = year.to_i
    week = week.to_i
    start_date = WeekCalculation.week_start_date(year, week, wday_start)
    new(type: :week, year: year, week: week, start_date: start_date, end_date: start_date + 6)
  end

  def self.month(year, month)
    start_date = Date.new(year.to_i, month.to_i, 1)
    new(type: :month, year: year.to_i, month: month.to_i, start_date: start_date, end_date: start_date.end_of_month)
  end

  private_class_method :new

  def initialize(type:, start_date:, end_date:, year: nil, month: nil, week: nil, date: nil)
    @type = type
    @start_date = start_date
    @end_date = end_date
    # only .recent leaves it implicit - nothing reads a recent window's year
    @year = year || end_date.year
    @month = month
    @week = week
    @date = date
  end

  def recent? = type == :recent

  def range = start_date..end_date

  def time_range = start_date.beginning_of_day..end_date.end_of_day

  def to_h
    case type
    when :recent then { type: :recent }
    when :year   then { type: :year, year: year }
    when :day    then { type: :day, date: date }
    when :week   then { type: :week, year: year, week: week, start_date: start_date, end_date: end_date }
    when :month  then { type: :month, year: year, month: month }
    end
  end
end
