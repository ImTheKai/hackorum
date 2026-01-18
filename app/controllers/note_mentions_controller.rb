# frozen_string_literal: true

class NoteMentionsController < ApplicationController
  before_action :require_authentication
  before_action :set_mention

  def destroy
    authorize_removal!
    return if performed?

    @mention.destroy

    redirect_back fallback_location: topic_path(@mention.note.topic), notice: "Mention removed"
  end

  private

  def set_mention
    @mention = NoteMention.find(params[:id])
  end

  def authorize_removal!
    mentionable = @mention.mentionable

    case mentionable
    when User
      unless mentionable.id == current_user.id
        redirect_back fallback_location: topic_path(@mention.note.topic), alert: "You can only remove your own mentions"
      end
    when Team
      unless mentionable.admin?(current_user)
        redirect_back fallback_location: topic_path(@mention.note.topic), alert: "Only team admins can remove team mentions"
      end
    else
      redirect_back fallback_location: topic_path(@mention.note.topic), alert: "Cannot remove this mention"
    end
  end
end
