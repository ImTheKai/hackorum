module PatchCi
  # The computed forecast. Pure DB reads - no git, no network - so the web UI
  # can render exactly what the orchestrator will execute next.
  class Planner
    WorkItem = Struct.new(:kind, :patch_branch, :message, keyword_init: true) do
      def topic_id = (patch_branch || message).topic_id

      # the message's topic is the preloaded one, patch_branch is the fallback
      def topic = (message || patch_branch).topic
    end

    def initialize(repo_state: PatchCiRepoState.current)
      @repo_state = repo_state
    end

    def plan(limit: Config::UP_NEXT_LIST)
      return [] unless @repo_state
      items = []
      seen_topics = []
      [ [ :new_version, method(:new_version_scope) ],
        [ :backfill,    method(:backfill_scope) ],
        [ :rebase,      method(:rebase_scope) ] ].each do |kind, scope|
        remaining = limit && limit - items.size
        break if remaining == 0
        rel = scope.call
        # one item per topic: a new version supersedes the old row, so a
        # same-topic lower-tier item is dead work. Filtering in SQL keeps the
        # limit filled instead of spending a slot on a dropped row.
        rel = rel.where.not(topic_id: seen_topics) if seen_topics.any?
        rel = rel.limit(remaining) if remaining
        # and one item per topic inside the tier too: two applied rows of the
        # same topic would both be pushed in one cycle, the second one already
        # superseded by the first. Trimming after the limit can return fewer
        # items than asked for - the caller plans with headroom for that.
        tier = build_items(kind, rel).uniq(&:topic_id)
        seen_topics.concat(tier.map(&:topic_id))
        items.concat(tier)
      end
      items
    end

    # raw per-tier totals: unlike plan these are not topic-deduped, so one
    # topic can be counted in two tiers
    def counts
      return { new_version: 0, backfill: 0, rebase: 0 } unless @repo_state
      { new_version: new_version_scope.count(:all),
        backfill: backfill_scope.count(:all),
        rebase: rebase_scope.count(:all) }
    end

    private

    def build_items(kind, relation)
      if kind == :new_version
        relation.includes(:topic).map { |msg| WorkItem.new(kind: kind, message: msg) }
      else
        relation.includes(message: :topic).map do |row|
          WorkItem.new(kind: kind, patch_branch: row, message: row.message)
        end
      end
    end

    def eligible_topics
      Topic.active.where.not(id: CommitTopic.select(:topic_id))
    end

    # inherits eligible_topics on purpose: committed/merged topics are retired
    # from all tiers, BranchHealth shows them as wont_retry
    def active_topics
      eligible_topics.where("last_message_at >= ?", Config::ACTIVE_THREAD_DAYS.days.ago)
    end

    # latest patch message per topic with no row of its own yet.
    # The subquery selects sort keys only so it stays an index only scan -
    # DISTINCT ON over full rows sorts bodies and tsvectors to disk. The
    # WORK_FROM floor sits inside it because the DISTINCT ON row is the topic's
    # newest patch message: if that one is under the floor, none in the topic
    # is above it, so filtering early cannot hide a later message.
    def new_version_scope
      latest = Message
        .select("DISTINCT ON (topic_id) id")
        .where(is_patch_submission: true)
        .where("created_at >= ?", Config::WORK_FROM)
        .order(:topic_id, created_at: :desc, id: :desc)

      # IN + NOT EXISTS, never JOIN + LEFT JOIN IS NULL: with COUNT(*) the join
      # form loses the row fetch that made a hash join look cheap and collapses
      # into a nested loop rescanning every message (60s+ on dev). Semi and anti
      # joins keep their shape whether the outer select is rows or a count.
      Message
        .where(id: latest)
        .where(topic_id: eligible_topics.select(:id))
        .where("NOT EXISTS (SELECT 1 FROM patch_branches pb WHERE pb.message_id = messages.id)")
        .order(created_at: :desc, id: :desc)
    end

    def backfill_scope
      PatchBranch.current.applied
        .where(pushed_at: nil)
        # a push that just failed fails the same way a second later, and it
        # sits at the head of this queue; give it a rest before retrying
        # qualified: this scope joins messages, which carries both columns
        .where("patch_branches.ci_status IS NULL OR (patch_branches.ci_status = 'push_failed'" \
               " AND patch_branches.updated_at < ?)", Config::PUSH_RETRY_MINUTES.minutes.ago)
        .where(topic_id: eligible_topics.select(:id))
        .joins(:message)
        .order("messages.created_at DESC, messages.id DESC")
    end

    def rebase_scope
      stale_cutoff = @repo_state.master_committed_at - Config::REBASE_AFTER_DAYS.days
      PatchBranch.current
        .where(topic_id: active_topics.select(:id))
        .where(<<~SQL, cutoff: stale_cutoff)
          (
            (pushed_at IS NOT NULL AND status = 'applied'
              AND (base_committed_at < :cutoff OR base_committed_at IS NULL
                   OR master_apply_error IS NOT NULL))
            OR (status = 'failed' AND pushed_at IS NULL AND failure_stage IN ('apply', 'base_detection'))
          )
        SQL
        # a force-push would burn the running slot and void the verdict, so leave
        # in-flight rows alone. StuckRunMarker flips silent ones to infra_error
        # after 48h, which re-enters them here - no permanent wedge.
        .where("ci_status IS NULL OR ci_status NOT IN (?)", PatchCiRun::IN_FLIGHT_BRANCH_STATUSES)
        .where("last_master_apply_at IS NULL OR last_master_apply_at < ?",
               @repo_state.master_committed_at)
        # least recently attempted first, so a chronic failure cannot camp at
        # the head of the queue: it goes to the back until master moves again
        .order(Arel.sql("last_master_apply_at ASC NULLS FIRST, base_committed_at ASC NULLS FIRST, id ASC"))
    end
  end
end
