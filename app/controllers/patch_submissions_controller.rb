class PatchSubmissionsController < ApplicationController
  DEFAULT_PER = 500
  MAX_PER = 1000

  def index
    per = params[:per].present? ? params[:per].to_i.clamp(1, MAX_PER) : DEFAULT_PER

    scope = Message.where(id: PatchSubmissionFile.select(:message_id).distinct)
    if params[:since].present?
      time, id = parse_cursor(params[:since])
      return head :bad_request unless time
      scope = scope.where("(messages.created_at, messages.id) > (?, ?)", time, id)
    end
    if params[:until].present?
      bound = parse_time(params[:until])
      return head :bad_request unless bound
      scope = scope.where(created_at: ..bound)
    end

    messages = scope.includes(:patch_submission_files, :sender, :topic)
                    .order(:created_at, :id).limit(per).to_a
    last = messages.last
    render json: {
      patch_submissions: messages.map { |m| submission_json(m) },
      next_cursor: last && "#{last.created_at.utc.iso8601(6)},#{last.id}"
    }
  end

  private

  def submission_json(m)
    {
      id: m.id,
      message_id: m.message_id,
      topic_id: m.topic_id,
      topic_title: m.topic.title,
      sender: m.sender.name,
      date: m.created_at.utc.iso8601(6),
      paths: m.patch_submission_files.map(&:path)
    }
  end

  def parse_cursor(raw)
    time_part, id_part = raw.split(",", 2)
    [ parse_time(time_part), id_part.to_i ]
  end

  def parse_time(raw)
    Time.zone.parse(raw)
  rescue ArgumentError
    nil
  end
end
