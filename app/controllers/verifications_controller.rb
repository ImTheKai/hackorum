class VerificationsController < ApplicationController
  # GET /verify?token=...
  def show
    raw = params[:token].to_s
    token = UserToken.consume!(raw)
    return redirect_to root_path, alert: 'Invalid or expired token' unless token

    case token.purpose
    when 'register'
      handle_register(token)
    when 'add_alias'
      handle_add_alias(token)
    when 'reset_password'
      redirect_to edit_password_path(token: raw)
    else
      redirect_to root_path, alert: 'Invalid token purpose'
    end
  end

  private

  def handle_register(token)
    existing_aliases = Alias.by_email(token.email)
    # If email already linked to another user, block registration
    if existing_aliases.where.not(user_id: nil).exists?
      return redirect_to new_session_path, alert: 'This email is already claimed. Please sign in.'
    end

    user = User.new
    metadata = JSON.parse(token.metadata || '{}') rescue {}
    desired_username = metadata['username']
    user.username = desired_username
    if metadata['password'].present?
      user.password = metadata['password']
      user.password_confirmation = metadata['password_confirmation']
    end
    begin
      user.save!(context: :registration)
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      if e.message =~ /username/i
        return redirect_to new_registration_path, alert: "Username is already taken."
      else
        raise
      end
    end

    if existing_aliases.exists?
      existing_aliases.update_all(user_id: user.id, verified_at: Time.current)
      # Ensure one primary alias
      primary = existing_aliases.find_by(primary_alias: true) || existing_aliases.first
      primary.update!(primary_alias: true)
    else
      # Use provided name if any
      name = metadata['name'] || token.email
      Alias.create!(user: user, name: name, email: token.email, primary_alias: true, verified_at: Time.current)
    end

    reset_session
    session[:user_id] = user.id
    redirect_to root_path, notice: 'Registration complete. You are signed in.'
  end

  def handle_add_alias(token)
    require_authentication
    email = token.email
    # Block if email belongs to another active user
    if Alias.by_email(email).where.not(user_id: [nil, current_user.id]).exists?
      return redirect_to settings_path, alert: 'Email is linked to another account. Delete that account first to release it.'
    end

    aliases = Alias.by_email(email)
    if aliases.exists?
      aliases.update_all(user_id: current_user.id, verified_at: Time.current)
    else
      Alias.create!(user: current_user, name: email, email: email, verified_at: Time.current)
    end

    redirect_to settings_path, notice: 'Email added and verified.'
  end
end
