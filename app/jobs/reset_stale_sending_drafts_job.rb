class ResetStaleSendingDraftsJob < ApplicationJob
  queue_as :default

  def perform
    OutgoingDraft.stale_sending.find_each do |draft|
      draft.update!(
        status: OutgoingDraft::STATUS_IDLE,
        last_send_error: "Send was stuck — please try again",
        sending_started_at: nil
      )
    end
  end
end
