module TeamStatsHelper
  def format_duration_hours(hours)
    return "–" if hours.nil?
    hours < 24 ? "#{hours.round(1)}h" : "#{(hours / 24.0).round(1)}d"
  end
end
