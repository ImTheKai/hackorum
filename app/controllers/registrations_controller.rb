class RegistrationsController < ApplicationController
  def new
  end

  # Handles both existing alias and new alias registration request initiation.
  def create
    email = EmailNormalizer.normalize(params[:email])
    name = params[:name]
    username = params[:username]
    password = params[:password]
    password_confirmation = params[:password_confirmation]

    if username.blank? || password.blank?
      return redirect_to registration_path, alert: "Username and password are required."
    end

    if User.exists?(username: username)
      return redirect_to registration_path, alert: "Username is already taken."
    end

    purpose = 'register'
    ttl = 1.hour
    token, raw = UserToken.issue!(
      purpose: purpose,
      email: email,
      ttl: ttl,
      metadata: {
        name: name,
        username: username,
        password: password,
        password_confirmation: password_confirmation
      }.to_json
    )

    UserMailer.verification_email(token, raw).deliver_later
    redirect_to root_path, notice: 'Verification email sent. Please check your inbox.'
  end
end
