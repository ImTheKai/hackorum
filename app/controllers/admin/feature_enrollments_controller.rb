# frozen_string_literal: true

class Admin::FeatureEnrollmentsController < Admin::BaseController
  before_action :set_feature

  def active_admin_section
    :features
  end

  def create
    identifier = params[:identifier].to_s.strip
    user = find_user(identifier)
    if user.nil?
      return redirect_to admin_feature_path(@feature), alert: "No user matched '#{identifier}'."
    end

    user.user_features.find_or_create_by!(feature: @feature)
    redirect_to admin_feature_path(@feature), notice: "Enrolled #{user.username || user.id}."
  end

  def destroy
    user = User.find(params[:user_id])
    user.user_features.where(feature: @feature).destroy_all
    redirect_to admin_feature_path(@feature), notice: "Removed enrollment."
  end

  private

  def set_feature
    @feature = params[:feature_name].to_s
    unless Feature.valid?(@feature)
      render plain: "Not found", status: :not_found
    end
  end

  def find_user(identifier)
    return nil if identifier.blank?
    User.find_by(username: identifier) || User.joins(:aliases).merge(Alias.by_email(identifier)).first
  end
end
