# frozen_string_literal: true

class MessagesController < ApplicationController
  before_action :require_authentication, only: [ :read ]

  def by_message_id
    raw = params[:message_id].to_s
    decoded = CGI.unescape(raw.gsub("+", "%2B"))
    message = Message.includes(topic: :mailing_lists).find_by(message_id: decoded)

    respond_to do |format|
      format.html do
        if message
          anchor = view_context.message_id_anchor(message) || view_context.message_dom_id(message)
          redirect_to topic_path(message.topic, anchor: anchor)
        else
          render plain: "Message not found", status: :not_found
        end
      end
      format.json do
        if message
          render json: {
            message_id: message.message_id,
            topic_id: message.topic_id,
            topic_title: message.topic.title,
            mailing_lists: message.topic.mailing_lists.map(&:identifier)
          }
        else
          render json: { error: "Message not found" }, status: :not_found
        end
      end
    end
  end

  def content
    @message = Message.eager_load(
      :sender,
      :sender_person,
      { sender_person: :default_alias },
      :attachments
    ).find(params[:id])
    @topic = @message.topic

    if user_signed_in?
      ranges = MessageReadRange.where(user: current_user, topic: @topic)
                               .order(:range_start_message_id)
                               .pluck(:range_start_message_id, :range_end_message_id)
      @read_message_ids = {}
      @read_message_ids[@message.id] = ranges.any? { |(s, e)| s <= @message.id && @message.id <= e }

      notes = Note.active.visible_to(current_user)
                  .where(topic: @topic, message: @message)
                  .includes(
                    :note_tags,
                    { author: { person: :default_alias } },
                    { last_editor: { person: :default_alias } },
                    { note_mentions: :mentionable }
                  )
                  .order(:created_at)
      @notes_by_message = Hash.new { |h, k| h[k] = [] }
      notes.each { |note| @notes_by_message[note.message_id] << note }
    end

    render layout: false
  end

  def patchset
    message = Message.includes(:attachments, :topic).find(params[:id])
    return head :not_found unless message.is_patch_submission

    archive = PatchsetArchive.build(
      message: message,
      attachment_number: message.topic.chronological_index_of(message),
      host: request.host_with_port
    )
    return head :not_found unless archive

    send_data archive[:data],
              filename: archive[:filename],
              type: "application/gzip",
              disposition: "attachment"
  end

  def read
    message = Message.find(params[:id])
    MessageReadRange.add_range(user: current_user, topic: message.topic, start_id: message.id, end_id: message.id)
    ThreadAwareness.mark_until(user: current_user, topic: message.topic, until_message_id: message.id)

    respond_to do |format|
      format.json { render json: { status: "ok" } }
      format.html { head :ok }
    end
  end
end
