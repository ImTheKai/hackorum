class DraftsController < ApplicationController
  before_action :require_authentication
  before_action :set_draft, only: [ :update, :destroy, :confirm, :send_now, :edit ]

  def create
    parent = Message.find(params[:reply_to_message_id])
    identity = current_user.identities.send_authorized.first
    return head :forbidden if identity.nil?

    sender = current_user.aliases.find_by(email: identity.email)
    return head :unprocessable_entity if sender.nil?

    draft = current_user.outgoing_drafts.find_by(reply_to_message_id: parent.id)
    draft ||= begin
      current_user.outgoing_drafts.create!(
        topic: parent.topic,
        reply_to_message: parent,
        identity: identity,
        sender_alias: sender,
        subject: build_default_subject(parent),
        body: ""
      )
    rescue ActiveRecord::RecordNotUnique
      current_user.outgoing_drafts.find_by!(reply_to_message_id: parent.id)
    end

    @draft = draft
    respond_to do |format|
      format.json { render json: { id: draft.id } }
      format.turbo_stream # renders create.turbo_stream.slim
      format.html { redirect_to topic_path(parent.topic, anchor: "message-#{parent.id}") }
    end
  end

  def edit
    render partial: "drafts/composer", locals: { draft: @draft }, layout: false
  end

  def update
    return head :conflict if @draft.sending?
    @draft.update!(draft_params)
    head :no_content
  end

  def destroy
    @draft.destroy!
    head :no_content
  end

  def confirm
    @recipient = Outgoing::RecipientResolver.for(@draft.topic)
    render layout: false
  rescue Outgoing::RecipientResolver::MissingPostAddressError
    render plain: "This mailing list isn't configured for sending. An admin must set its post_address.",
           status: :unprocessable_entity
  rescue Outgoing::RecipientResolver::MissingDevOverrideError
    render plain: "Dev mode requires HACKORUM_DEV_REPLY_TO env var to be set.",
           status: :unprocessable_entity
  rescue Outgoing::RecipientResolver::RealListAddressInDevError
    render plain: "Refusing to send: HACKORUM_DEV_REPLY_TO matches a real list address. Change it to a personal mailbox.",
           status: :unprocessable_entity
  end

  def send_now
    conflict = nil
    @draft.with_lock do
      conflict = "Draft is already being sent." unless @draft.idle?
      next if conflict

      @draft.update!(
        status: OutgoingDraft::STATUS_SENDING,
        sending_started_at: Time.current,
        last_send_error: nil
      )
    end

    if conflict
      return render plain: conflict, status: :conflict
    end

    # Sync send: by the time the redirect runs, the draft is either destroyed
    # (success), reset to idle with last_send_error (permanent), or still in
    # sending status (transient — retry_on rescued and re-enqueued the job).
    # The composer partial renders a "Sending…" placeholder for that last case.
    SendOutgoingMessageJob.perform_now(@draft.id)
    redirect_to topic_path(@draft.topic, anchor: "message-#{@draft.reply_to_message_id}")
  end

  private

  def set_draft
    @draft = current_user.outgoing_drafts.find(params[:id])
  end

  def draft_params
    params.require(:outgoing_draft).permit(:subject, :body)
  end

  def build_default_subject(parent)
    base = parent.subject.to_s.sub(/\A(re|aw|fwd):\s*/i, "")
    "Re: #{base}"
  end
end
