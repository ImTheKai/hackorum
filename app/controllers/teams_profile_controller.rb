class TeamsProfileController < ApplicationController
  include ProfileActivity

  before_action :load_team
  before_action :require_team_accessible!

  def show
    @members = @team.team_members.includes(user: { person: :default_alias }).order(:role, :created_at)
    load_activity_data
    load_team_stats
  end

  def contributions
    load_activity_data
    load_team_stats
    render :activity
  end

  def daily_activity
    date = parse_activity_date
    @activity_period = { type: :day, date: date }
    load_activity_data(
      scope: messages_scope_for_date(date), year: date.year,
      window_start: date.beginning_of_day, window_end: date.end_of_day
    )
    load_team_stats
    render :activity
  end

  def monthly_activity
    year = params[:year].to_i
    month = params[:month].to_i
    start_date = Date.new(year, month, 1)
    end_date = start_date.end_of_month
    @activity_period = { type: :month, year: year, month: month }
    load_activity_data(
      scope: messages_scope_for_range(start_date, end_date), year: year,
      window_start: start_date.beginning_of_day, window_end: end_date.end_of_day
    )
    load_team_stats
    render :activity
  end

  def weekly_activity
    year = params[:year].to_i
    week = params[:week].to_i
    wday_start = parse_week_start_day
    start_date = WeekCalculation.week_start_date(year, week, wday_start)
    end_date = start_date + 6
    @activity_period = { type: :week, year: year, week: week, start_date: start_date, end_date: end_date }
    load_activity_data(
      scope: messages_scope_for_range(start_date, end_date), year: year,
      window_start: start_date.beginning_of_day, window_end: end_date.end_of_day
    )
    load_team_stats
    render :activity
  end

  private

  def activity_person_ids
    @member_person_ids
  end

  def parse_week_start_day
    return WeekCalculation.parse_week_start(params[:week_start]) if params[:week_start].present?
    @team.week_start_day
  end

  def load_team_stats
    @team_stats = TeamActivityStats.new(
      team_person_ids: @member_person_ids,
      window_start: @activity_window_start,
      window_end: @activity_window_end
    ).call
  end

  def load_team
    @team = Team.find_by!(name: params[:name])
    @member_person_ids = @team.users.joins(:person).pluck("people.id").to_set
  end

  def require_team_accessible!
    return if @team.accessible_to?(current_user)

    if user_signed_in?
      render_404
    else
      redirect_to new_session_path, alert: "Please sign in"
    end
  end
end
