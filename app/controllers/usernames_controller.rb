# frozen_string_literal: true

class UsernamesController < ApplicationController
  before_action :require_authentication

  def update
    if current_user.update(username_params)
      redirect_to settings_path, notice: "Username updated"
    else
      redirect_to settings_path, alert: current_user.errors.full_messages.to_sentence
    end
  end

  private

  def username_params
    params.require(:user).permit(:username)
  end
end
