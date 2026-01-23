module ProfileHelper
  def profile_filter_url(profile_routes, activity_period)
    return profile_routes[:default] if activity_period.nil?

    case activity_period[:type]
    when :day
      profile_routes[:daily].call(activity_period[:date].iso8601)
    when :week
      profile_routes[:weekly].call(activity_period[:year], activity_period[:week])
    when :month
      profile_routes[:monthly].call(activity_period[:year], activity_period[:month])
    else
      profile_routes[:default]
    end
  end

  def person_profile_routes(email, week_start: nil)
    ws = week_start ? { week_start: week_start } : {}
    {
      default: person_path(email, **ws),
      daily: ->(date) { person_activity_path(email, date, **ws) },
      weekly: ->(year, week) { person_weekly_activity_path(email, year, week, **ws) },
      monthly: ->(year, month) { person_monthly_activity_path(email, year, month, **ws) },
      contributions: ->(year) { person_contributions_path(email, year: year, **ws) }
    }
  end

  def team_profile_routes(name, week_start: nil)
    ws = week_start ? { week_start: week_start } : {}
    {
      default: team_profile_path(name, **ws),
      daily: ->(date) { team_activity_path(name, date, **ws) },
      weekly: ->(year, week) { team_weekly_activity_path(name, year, week, **ws) },
      monthly: ->(year, month) { team_monthly_activity_path(name, year, month, **ws) },
      contributions: ->(year) { team_contributions_path(name, year: year, **ws) }
    }
  end
end
