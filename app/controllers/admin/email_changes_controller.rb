# frozen_string_literal: true

class Admin::EmailChangesController < Admin::BaseController
  def active_admin_section
    :email_changes
  end

  def index
    @email_changes = AdminEmailChange.includes(performed_by: { person: :default_alias },
                                               target_user: { person: :default_alias })
                                     .order(created_at: :desc)
                                     .limit(100)
  end
end
