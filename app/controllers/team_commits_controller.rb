class TeamCommitsController < ApplicationController
  include TeamProfileScope
  include ProfilePeriodActions
  include ProfileCommitActivity

  def show
    render_activity_period(default_activity_period)
  end
end
