# frozen_string_literal: true

class TeamActivityStats
  BACKLOG_CAP = 90.days

  Result = Struct.new(
    :new_thread_count, :joined_thread_count, :continuing_thread_count,
    :median_first_response_hours, :first_response_sample_size,
    :waiting_for_response_count, :patches_waiting_for_update_count,
    :external_reply_pct_within_2_bdays, :external_reply_pct_within_5_bdays,
    :external_reply_response_events_count,
    :unique_external_contributor_count, :threads_with_further_engagement_count,
    keyword_init: true
  )

  def initialize(team_person_ids:, window_start:, window_end:)
    ids = team_person_ids.is_a?(Set) ? team_person_ids.to_a : Array(team_person_ids)
    @team_person_ids = ids
    @window_start = window_start
    @window_end = window_end
  end

  def call
    return empty_result if @team_person_ids.blank?

    topic_ids = window_topic_ids
    window_stats = topic_ids.any? ? window_dependent_stats(topic_ids) : empty_window_stats

    Result.new(
      **window_stats,
      waiting_for_response_count: waiting_for_response_count,
      patches_waiting_for_update_count: patches_waiting_for_update_count
    )
  end

  private

  def window_topic_ids
    Message.where(sender_person_id: @team_person_ids, created_at: @window_start..@window_end)
           .distinct.pluck(:topic_id)
  end

  def window_dependent_stats(topic_ids)
    empty_window_stats
      .merge(thread_breakdown(topic_ids))
      .merge(first_response_stats(topic_ids))
      .merge(external_reply_business_day_stats(topic_ids))
      .merge(
        unique_external_contributor_count: unique_external_contributor_count(topic_ids),
        threads_with_further_engagement_count: threads_with_further_engagement_count(topic_ids)
      )
  end

  def team_first_message_at_by_topic(topic_ids)
    TopicParticipant.where(topic_id: topic_ids, person_id: @team_person_ids)
                     .group(:topic_id).minimum(:first_message_at)
  end

  def thread_breakdown(topic_ids)
    team_first_at = team_first_message_at_by_topic(topic_ids)
    creator_by_topic = Topic.where(id: topic_ids).pluck(:id, :creator_person_id).to_h
    team_id_set = @team_person_ids.to_set
    new_count = 0
    joined_count = 0
    continuing_count = 0

    topic_ids.each do |topic_id|
      first_at = team_first_at[topic_id]
      next unless first_at # defensive: a team message in-window guarantees a TopicParticipant row

      if @window_start <= first_at && first_at <= @window_end
        team_id_set.include?(creator_by_topic[topic_id]) ? new_count += 1 : joined_count += 1
      else
        continuing_count += 1
      end
    end

    { new_thread_count: new_count, joined_thread_count: joined_count, continuing_thread_count: continuing_count }
  end

  def first_response_stats(topic_ids)
    team_first_at = team_first_message_at_by_topic(topic_ids)
    external_topic_ids = Topic.where(id: topic_ids).where.not(creator_person_id: @team_person_ids).pluck(:id)
    topic_created_at = Topic.where(id: external_topic_ids).pluck(:id, :created_at).to_h

    deltas = external_topic_ids.filter_map do |topic_id|
      first_at = team_first_at[topic_id]
      next unless first_at && @window_start <= first_at && first_at <= @window_end

      first_at - topic_created_at[topic_id]
    end

    return { median_first_response_hours: nil, first_response_sample_size: 0 } if deltas.empty?

    { median_first_response_hours: (median(deltas) / 1.hour).round(1), first_response_sample_size: deltas.size }
  end

  def median(values)
    sorted = values.sort
    mid = sorted.length / 2
    sorted.length.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
  end

  def waiting_for_response_count
    Topic.joins(:topic_participants)
         .where(topic_participants: { person_id: @team_person_ids })
         .where.not(last_sender_person_id: @team_person_ids)
         .where(last_message_at: BACKLOG_CAP.ago..)
         .distinct.count(:id)
  end

  def patches_waiting_for_update_count
    team_first_patch_msg_id_by_topic = Message.where(sender_person_id: @team_person_ids, is_patch_submission: true)
                                               .group(:topic_id).minimum(:id)
    return 0 if team_first_patch_msg_id_by_topic.empty?

    topic_wide_first_patch_id = Message.where(topic_id: team_first_patch_msg_id_by_topic.keys, is_patch_submission: true)
                                        .group(:topic_id).minimum(:id)
    matching_topic_ids = team_first_patch_msg_id_by_topic.select { |tid, mid| topic_wide_first_patch_id[tid] == mid }.keys

    Topic.where(id: matching_topic_ids)
         .where.not(last_sender_person_id: @team_person_ids)
         .where(last_message_at: BACKLOG_CAP.ago..)
         .count
  end

  def external_reply_business_day_stats(topic_ids)
    rows = Message.where(topic_id: topic_ids).order(:created_at).pluck(:topic_id, :sender_person_id, :created_at)
    deltas_bdays = []

    rows.group_by(&:first).each_value do |topic_rows|
      pending_external_at = nil
      topic_rows.each do |(_topic_id, sender_id, created_at)|
        if @team_person_ids.include?(sender_id)
          if pending_external_at
            deltas_bdays << BusinessDays.between(pending_external_at, created_at)
            pending_external_at = nil
          end
        else
          pending_external_at ||= created_at
        end
      end
    end

    if deltas_bdays.empty?
      return {
        external_reply_pct_within_2_bdays: nil, external_reply_pct_within_5_bdays: nil,
        external_reply_response_events_count: 0
      }
    end

    {
      external_reply_pct_within_2_bdays: (deltas_bdays.count { |d| d <= 2 } * 100.0 / deltas_bdays.size).round(1),
      external_reply_pct_within_5_bdays: (deltas_bdays.count { |d| d <= 5 } * 100.0 / deltas_bdays.size).round(1),
      external_reply_response_events_count: deltas_bdays.size
    }
  end

  def unique_external_contributor_count(topic_ids)
    TopicParticipant.where(topic_id: topic_ids).where.not(person_id: @team_person_ids).distinct.count(:person_id)
  end

  def threads_with_further_engagement_count(topic_ids)
    team_last_at = Message.where(topic_id: topic_ids, sender_person_id: @team_person_ids, created_at: @window_start..@window_end)
                          .group(:topic_id).maximum(:created_at)
    return 0 if team_last_at.empty?

    external_last_at = Message.where(topic_id: team_last_at.keys).where.not(sender_person_id: @team_person_ids)
                               .group(:topic_id).maximum(:created_at)

    team_last_at.count { |topic_id, team_at| external_last_at[topic_id] && external_last_at[topic_id] > team_at }
  end

  def empty_window_stats
    {
      new_thread_count: 0, joined_thread_count: 0, continuing_thread_count: 0,
      median_first_response_hours: nil, first_response_sample_size: 0,
      external_reply_pct_within_2_bdays: nil, external_reply_pct_within_5_bdays: nil,
      external_reply_response_events_count: 0,
      unique_external_contributor_count: 0, threads_with_further_engagement_count: 0
    }
  end

  def empty_result
    Result.new(**empty_window_stats, waiting_for_response_count: 0, patches_waiting_for_update_count: 0)
  end
end
