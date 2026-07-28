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

    # every tier gates on this, not just one; committed topics read as
    # wont_retry in BranchHealth. Thread activity is deliberately not part of
    # it, see ACTIVE_THREAD_DAYS in config.rb.
    def eligible_topics
      Topic.active.where.not(id: CommitTopic.select(:topic_id))
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

    # Every row worth re-probing: due (master moved since the last probe and the
    # throttle has expired) and not yet retired. Retirement is an exclusion here,
    # not the trigger: a row that keeps applying has its base moved forward every
    # day and never ages, a row that stops applying ages out within
    # REBASE_AFTER_DAYS. Nothing in here reads the discussion.
    def rebase_scope
      stale_cutoff = @repo_state.master_committed_at - Config::REBASE_AFTER_DAYS.days
      # every column qualified: the messages join carries a created_at too
      candidates = <<~SQL
        (
          -- pushed_at is not redundant with 'applied': it is what keeps this
          -- tier disjoint from backfill, which owns the never pushed rows.
          -- Without it counts double-reports the backfill queue as rebase work.
             (patch_branches.status = 'applied' AND patch_branches.pushed_at IS NOT NULL
              AND (patch_branches.base_committed_at >= :stale_cutoff
                   OR patch_branches.base_committed_at IS NULL)
              AND patch_branches.base_sha IS DISTINCT FROM :master_sha)
          -- no IS NULL escape here, unlike the applied clause above: unbounded
          -- probing is worth it for a row backing a live pushed branch whose
          -- verdict we report, and not for one that never produced a branch.
          -- The shape this excludes is not "no base" but a base sha we could not
          -- resolve to a date - the logged-warn path in PatchBranches::ApplyOne
          -- #save - so it is a trapdoor: such a row never returns here.
          OR (patch_branches.status = 'failed' AND patch_branches.pushed_at IS NULL
              AND patch_branches.failure_stage = 'apply'
              AND patch_branches.base_committed_at >= :stale_cutoff)
          OR (patch_branches.status = 'failed' AND patch_branches.pushed_at IS NULL
              AND patch_branches.failure_stage = 'base_detection'
              AND messages.created_at >= :submission_cutoff)
        )
      SQL

      PatchBranch.current
        .where(topic_id: eligible_topics.select(:id))
        # base_detection failures have no base to age, so they retire on the
        # submission date instead - joined for that one clause
        .joins(:message)
        # two clocks on purpose: base retirement runs off master_committed_at,
        # submission retirement off the wall clock, so a fetch broken for a week
        # freezes the first and not the second
        .where(candidates, stale_cutoff: stale_cutoff, master_sha: @repo_state.master_sha,
                           submission_cutoff: Config::REBASE_AFTER_DAYS.days.ago)
        # a force-push would burn the running slot and void the verdict, so leave
        # in-flight rows alone. StuckRunMarker flips silent ones to infra_error
        # after 48h, which re-enters them here - no permanent wedge.
        .where("patch_branches.ci_status IS NULL OR patch_branches.ci_status NOT IN (?)",
               PatchCiRun::IN_FLIGHT_BRANCH_STATUSES)
        # due = master moved since the last probe AND the throttle has expired.
        # Re-probing an unchanged patch against an unchanged master cannot
        # change the answer, so the first half spends nothing on no-ops.
        .where("patch_branches.last_master_apply_at IS NULL" \
               " OR (patch_branches.last_master_apply_at < :master_at" \
               " AND patch_branches.last_master_apply_at < :probe_cutoff)",
               master_at: @repo_state.master_committed_at,
               probe_cutoff: Config::MASTER_CHECK_AFTER_HOURS.hours.ago)
        # least recently attempted first, so a chronic failure cannot camp at
        # the head of the queue, and so a single sweep staggers the timestamps
        # it writes - the next day's queue arrives already spread out
        .order(Arel.sql("patch_branches.last_master_apply_at ASC NULLS FIRST," \
                        " patch_branches.base_committed_at ASC NULLS FIRST," \
                        " patch_branches.id ASC"))
    end
  end
end
