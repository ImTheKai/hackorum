# frozen_string_literal: true

class ActivitiesController < ApplicationController
  before_action :require_authentication

  def index
    @query = params[:q].to_s.strip
    @activities = base_scope
                    .then { |scope| apply_query(scope) }
                    .includes(subject: [:topic, :message])
                    .order(created_at: :desc)
                    .limit(100)
    mark_shown_as_read!(@activities)
    @unread_count = base_scope.unread.count
  end

  def mark_all_read
    base_scope.unread.update_all(read_at: Time.current)
    redirect_to activities_path, notice: "Marked all as read"
  end

  private

  def base_scope
    current_user.activities.visible
  end

  def apply_query(scope)
    return scope if @query.blank?

    scope.joins("INNER JOIN notes ON notes.id = activities.subject_id AND activities.subject_type = 'Note'")
         .where("notes.body ILIKE ?", "%#{@query}%")
  end

  def mark_shown_as_read!(activities)
    unread_ids = activities.select { |a| a.read_at.nil? }.map(&:id)
    return if unread_ids.empty?
    Activity.where(id: unread_ids).update_all(read_at: Time.current)
  end
end
