class AccountDeletionsController < ApplicationController
  before_action :require_authentication

  def new
  end

  def create
    # Optionally verify password or recent OIDC; for now, proceed if signed in
    unless params[:confirmation].to_s.strip == "DELETE"
      return redirect_to new_account_deletion_path, alert: "Please type DELETE to confirm."
    end

    perform_deletion!(current_user)
    reset_session
    redirect_to root_path, notice: 'Your account has been deleted.'
  end

  private

  def perform_deletion!(user)
    Identity.where(user_id: user.id).delete_all
    UserToken.where(user_id: user.id).delete_all
    user.aliases.update_all(user_id: nil, verified_at: nil)
    user.update!(password_digest: nil, deleted_at: Time.current)
  end
end
