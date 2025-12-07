class OmniauthCallbacksController < ApplicationController
  def google_oauth2
    auth = request.env['omniauth.auth']
    provider = auth['provider']
    uid = auth['uid']
    info = auth['info'] || {}
    email = info['email']

    identity = Identity.find_by(provider: provider, uid: uid)
    if identity
      user = identity.user
    else
      # Attach to existing verified alias user if present
      alias_user = Alias.by_email(email).where.not(verified_at: nil).includes(:user).first&.user
      user = alias_user || User.create!

      # If no aliases exist for this email, create one
      aliases = Alias.by_email(email)
      if aliases.exists?
        aliases.update_all(user_id: user.id, verified_at: Time.current)
        primary = aliases.find_by(primary_alias: true) || aliases.first
        primary.update!(primary_alias: true)
      else
        name = info['name'].presence || email
        Alias.create!(user: user, name: name, email: email, primary_alias: true, verified_at: Time.current)
      end

      identity = Identity.create!(user: user, provider: provider, uid: uid, email: email, raw_info: auth.to_json, last_used_at: Time.current)
    end

    identity.update!(last_used_at: Time.current)

    reset_session
    session[:user_id] = identity.user_id
    redirect_to root_path, notice: 'Signed in with Google'
  rescue => e
    Rails.logger.error("OIDC error: #{e.class}: #{e.message}")
    redirect_to new_session_path, alert: 'Could not sign in with Google.'
  end
end
