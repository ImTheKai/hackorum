module ProfilePeriodParams
  extend ActiveSupport::Concern

  private

  def parse_week_start_day
    WeekCalculation.parse_week_start(params[:week_start])
  end

  def parse_activity_date
    Date.iso8601(params[:date])
  rescue ArgumentError
    Date.current
  end
end
