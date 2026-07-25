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

  def profile_stat_tiles(stats, search_email)
    linkable = search_email.present?

    [
      {
        display: number_with_delimiter(stats.messages_sent),
        label: "Messages sent"
      },
      {
        display: number_with_delimiter(stats.threads_started),
        label: "Threads started",
        query: ("starter:\"#{search_email}\"" if linkable)
      },
      {
        display: number_with_delimiter(stats.threads_joined),
        label: "Threads joined",
        query: ("from:\"#{search_email}\"" if linkable)
      },
      {
        display: number_with_delimiter(stats.patches_sent),
        label: "Patches sent",
        sub: "across #{pluralize(stats.patch_threads, 'thread')}",
        title: "Threads they sent a patch to, including threads started by other people",
        query: ("has:patch[from:\"#{search_email}\"]" if linkable)
      },
      {
        display: profile_active_span(stats),
        label: "Active",
        sub: profile_active_range(stats)
      }
    ]
  end

  def profile_active_span(stats)
    return "-" unless stats.first_message_at

    years = stats.years_active
    years.positive? ? "#{years} yrs" : "< 1 yr"
  end

  def profile_active_range(stats)
    return nil unless stats.first_message_at && stats.last_message_at

    "#{stats.first_message_at.strftime('%b %Y')} - #{stats.last_message_at.strftime('%b %Y')}"
  end

  def profile_thread_lifetime(stats)
    days = stats.median_thread_lifetime_days
    return nil if days.nil?

    days < 1 ? "under a day" : pluralize(days.round, "day")
  end

  # Inclusive [start, end] dates for the period currently on screen.
  def profile_period_range(activity_period)
    return [ 30.days.ago.beginning_of_day.to_date, Date.current ] if activity_period.nil? || activity_period[:type] == :recent

    case activity_period[:type]
    when :day
      [ activity_period[:date], activity_period[:date] ]
    when :week
      [ activity_period[:start_date], activity_period[:end_date] ]
    when :month
      start_date = Date.new(activity_period[:year], activity_period[:month], 1)
      [ start_date, start_date.end_of_month ]
    else
      [ 30.days.ago.beginning_of_day.to_date, Date.current ]
    end
  end

  # first_after: is >= and first_before: is <, so the upper bound is the day after
  # the last day we want included.
  def profile_started_search_query(email, activity_period)
    return nil if email.blank?

    range_start, range_end = profile_period_range(activity_period)
    return nil unless range_start && range_end

    "starter:\"#{email}\" first_after:#{range_start} first_before:#{range_end + 1}"
  end
end
