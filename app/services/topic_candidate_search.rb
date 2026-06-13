# frozen_string_literal: true

class TopicCandidateSearch
  DEFAULT_LIMIT = 8
  MAX_LIMIT = 50

  BOOL_TYPE = ActiveModel::Type::Boolean.new

  PATCH_EXISTS_SQL = "EXISTS (SELECT 1 FROM messages m WHERE m.topic_id = topics.id AND m.is_patch_submission = true)"

  Result = Struct.new(
    :id, :title, :mailing_lists, :created_at, :last_message_at,
    :message_count, :has_patches, :first_message_snippet, :score,
    keyword_init: true
  )

  def initialize(q:, from:, to:, mailing_lists: [], patches_only: false, limit: DEFAULT_LIMIT)
    @q = q.to_s.strip
    @from = from
    @to = to
    @mailing_lists = Array(mailing_lists).reject(&:blank?)
    @patches_only = patches_only
    @limit = [ [ limit.to_i, 1 ].max, MAX_LIMIT ].min
  end

  def results
    scope.to_a.map { |t| to_result(t) }
  end

  private

  def scope
    relation = Topic.where(merged_into_topic_id: nil)
    relation = relation.where(created_at: @from..@to) if @from && @to
    relation = relation.where(created_at: @from..)    if @from && !@to
    relation = relation.where(created_at: ..@to)      if @to && !@from
    relation = apply_text(relation)
    relation = apply_mailing_lists(relation)
    relation = apply_patches_only(relation)
    relation
      .includes(:mailing_lists)
      .select(
        "topics.*",
        rank_select,
        "#{PATCH_EXISTS_SQL} AS has_patch_submission",
        "(SELECT body FROM messages WHERE messages.topic_id = topics.id ORDER BY created_at LIMIT 1) AS first_message_body"
      )
      .order(Arel.sql("relevance_score DESC NULLS LAST"), last_message_at: :desc)
      .limit(@limit)
  end

  def rank_select
    return "0 AS relevance_score" if @q.blank?
    Topic.sanitize_sql_array(["ts_rank(topics.title_tsv, websearch_to_tsquery('english', ?)) AS relevance_score", @q])
  end

  def apply_text(relation)
    return relation if @q.blank?

    relation.where(
      "topics.title_tsv @@ websearch_to_tsquery('english', :q) " \
      "OR EXISTS (SELECT 1 FROM messages WHERE messages.topic_id = topics.id " \
      "AND messages.body_tsv @@ websearch_to_tsquery('english', :q))",
      q: @q
    )
  end

  def apply_mailing_lists(relation)
    return relation if @mailing_lists.empty?

    relation.where(
      "EXISTS (SELECT 1 FROM topic_mailing_lists tml JOIN mailing_lists ml " \
      "ON ml.id = tml.mailing_list_id WHERE tml.topic_id = topics.id AND ml.identifier IN (?))",
      @mailing_lists
    )
  end

  def apply_patches_only(relation)
    return relation unless @patches_only

    relation.where(PATCH_EXISTS_SQL)
  end

  def to_result(topic)
    Result.new(
      id: topic.id,
      title: topic.title,
      mailing_lists: topic.mailing_lists.map(&:identifier),
      created_at: topic.created_at,
      last_message_at: topic.last_message_at,
      message_count: topic.message_count,
      has_patches: BOOL_TYPE.cast(topic.has_patch_submission),
      first_message_snippet: topic.first_message_body.to_s[0, 500],
      score: topic.relevance_score.to_f
    )
  end
end
