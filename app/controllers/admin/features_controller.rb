# frozen_string_literal: true

class Admin::FeaturesController < Admin::BaseController
  before_action :set_feature, only: [ :show ]

  def active_admin_section
    :features
  end

  def index
    @features = Feature::ALL
    @counts = UserFeature.group(:feature).count
  end

  def show
    @label = Feature.label(@feature)
    @enrolled_users = User.joins(:user_features)
                          .where(user_features: { feature: @feature })
                          .includes(person: :default_alias)
                          .order(:username)
  end

  private

  def set_feature
    @feature = params[:name].to_s
    unless Feature.valid?(@feature)
      render plain: "Not found", status: :not_found
    end
  end
end
