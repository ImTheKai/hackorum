# frozen_string_literal: true

class NotesController < ApplicationController
  before_action :require_authentication
  before_action :set_note, only: [:update]

  def create
    topic = Topic.find(note_params[:topic_id])
    message = resolve_message(topic)
    note = NoteBuilder.new(author: current_user).create!(topic:, message:, body: note_params[:body])

    redirect_to topic_path(topic, anchor: note_anchor(note)), notice: "Note added"
  rescue NoteBuilder::Error, ActiveRecord::RecordInvalid => e
    flash[:alert] = e.message
    flash[:note_error] = {
      body: note_params[:body],
      message_id: note_params[:message_id].presence,
      topic_id: note_params[:topic_id],
      error: e.message
    }
    redirect_back fallback_location: topic_path(topic)
  end

  def update
    return if performed?

    NoteBuilder.new(author: current_user).update!(note: @note, body: note_params[:body])

    redirect_to topic_path(@note.topic, anchor: note_anchor(@note)), notice: "Note updated"
  rescue NoteBuilder::Error, ActiveRecord::RecordInvalid => e
    flash[:alert] = e.message
    flash[:note_error] = {
      body: note_params[:body],
      message_id: note_params[:message_id].presence,
      topic_id: note_params[:topic_id],
      note_id: @note.id,
      error: e.message
    }
    redirect_back fallback_location: topic_path(@note.topic)
  end

  private

  def set_note
    @note = Note.find(params[:id])
    unless @note.author_id == current_user.id
      redirect_back fallback_location: topic_path(@note.topic), alert: "You can only edit your own notes"
      return
    end
  end

  def note_params
    params.require(:note).permit(:body, :topic_id, :message_id)
  end

  def resolve_message(topic)
    return nil if note_params[:message_id].blank?
    topic.messages.find(note_params[:message_id])
  end

  def note_anchor(note)
    if note.message_id
      view_context.message_dom_id(note.message)
    else
      "thread-notes"
    end
  end
end
