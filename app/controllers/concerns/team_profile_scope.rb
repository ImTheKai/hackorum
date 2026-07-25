module TeamProfileScope
  extend ActiveSupport::Concern

  included do
    before_action :load_team
    before_action :require_team_accessible!
  end

  private

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

  def activity_person_ids
    @member_person_ids
  end
end
