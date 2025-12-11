# frozen_string_literal: true

class AdminConstraint
  def matches?(request)
    user_id = request.session[:user_id]
    return false unless user_id

    user = User.active.find_by(id: user_id)
    user&.admin?
  end
end
