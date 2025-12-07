class SessionsController < ApplicationController
  def new
  end

  def create
    email = EmailNormalizer.normalize(params[:email])
    user = Alias.by_email(email).includes(:user).first&.user

    if user&.authenticate(params[:password]) && user.aliases.where.not(verified_at: nil).exists?
      reset_session
      session[:user_id] = user.id
      redirect_to root_path, notice: 'Signed in successfully'
    else
      flash.now[:alert] = 'Invalid email or password'
      render :new, status: :unauthorized
    end
  end

  def destroy
    reset_session
    redirect_to root_path, notice: 'Signed out'
  end
end

