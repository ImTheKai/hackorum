class ApplicationController < ActionController::Base
  allow_browser versions: :modern
  
  rescue_from ActiveRecord::RecordNotFound, with: :render_404
  helper_method :current_user, :user_signed_in?
  helper_method :activity_unread_count
  
  private
  
  def render_404
    render file: Rails.root.join('public', '404.html'), status: :not_found, layout: false
  end

  def current_user
    return @current_user if defined?(@current_user)
    uid = session[:user_id]
    @current_user = uid && User.active.find_by(id: uid)
  end

  def user_signed_in?
    current_user.present?
  end

  def require_authentication
    redirect_to new_session_path, alert: 'Please sign in' unless user_signed_in?
  end

  def activity_unread_count
    return 0 unless current_user
    @activity_unread_count ||= Activity.where(user: current_user, hidden: false, read_at: nil).count
  end
end
