# frozen_string_literal: true

class Admin::OutgoingMessagesController < Admin::BaseController
  def active_admin_section
    :outgoing_messages
  end

  def index
    @pending = Message.pending.order(sent_at: :desc).limit(200)
    @recent  = Message.sent.where.not(sent_via_identity_id: nil).order(sent_at: :desc).limit(200)
  end
end
