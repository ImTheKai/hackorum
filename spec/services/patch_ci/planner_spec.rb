require "rails_helper"

RSpec.describe PatchCi::Planner do
  let(:master_at) { Time.current.change(usec: 0) }
  let!(:repo_state) { create(:patch_ci_repo_state, master_committed_at: master_at) }

  def planner
    described_class.new(repo_state: PatchCiRepoState.current)
  end

  def kinds_of(items) = items.map(&:kind)

  def patch_message(topic, created_at: 2.days.ago)
    create(:message, topic: topic, created_at: created_at, is_patch_submission: true)
  end

  def items_of(kind, limit: nil)
    planner.plan(limit: limit).select { |item| item.kind == kind }
  end

  describe "tier 1 new_version" do
    it "emits the latest patch message that has no branch row" do
      topic = create(:topic)
      msg = patch_message(topic)

      items = items_of(:new_version)

      expect(items.map(&:message)).to eq([ msg ])
      expect(items.first.patch_branch).to be_nil
    end

    it "does not emit when a row exists for that exact message, even a failed one" do
      topic = create(:topic)
      msg = patch_message(topic)
      create(:patch_branch, topic: topic, message: msg, status: "failed", failure_stage: "extract")

      expect(items_of(:new_version)).to be_empty
    end

    it "does not emit messages older than WORK_FROM" do
      topic = create(:topic)
      patch_message(topic, created_at: PatchCi::Config::WORK_FROM - 1.year)

      expect(items_of(:new_version)).to be_empty
    end

    it "does not emit merged topics" do
      target = create(:topic)
      topic = create(:topic, merged_into_topic_id: target.id)
      patch_message(topic)

      expect(items_of(:new_version)).to be_empty
    end

    it "does not emit topics that already have a commit" do
      topic = create(:topic)
      patch_message(topic)
      create(:commit_topic, topic: topic)

      expect(items_of(:new_version)).to be_empty
    end

    it "emits the topic when only an older message has a row" do
      topic = create(:topic)
      old_msg = patch_message(topic, created_at: 10.days.ago)
      new_msg = patch_message(topic, created_at: 1.day.ago)
      create(:patch_branch, topic: topic, message: old_msg,
                            status: "failed", failure_stage: "extract")

      expect(items_of(:new_version).map(&:message)).to eq([ new_msg ])
    end

    it "orders newest message first" do
      older = patch_message(create(:topic), created_at: 5.days.ago)
      newer = patch_message(create(:topic), created_at: 1.day.ago)

      expect(items_of(:new_version).map(&:message)).to eq([ newer, older ])
    end
  end

  describe "tier 2 backfill" do
    it "emits applied rows never pushed with no ci_status" do
      topic = create(:topic)
      row = create(:patch_branch, topic: topic, status: "applied", pushed_at: nil, ci_status: nil)

      items = items_of(:backfill)

      expect(items.map(&:patch_branch)).to eq([ row ])
      expect(items.first.message).to eq(row.message)
    end

    it "emits push_failed rows once the retry backoff expired" do
      row = create(:patch_branch, status: "applied", pushed_at: nil, ci_status: "push_failed",
                                  updated_at: (PatchCi::Config::PUSH_RETRY_MINUTES + 1).minutes.ago)

      expect(items_of(:backfill).map(&:patch_branch)).to eq([ row ])
    end

    it "holds back a push_failed row still inside the backoff" do
      create(:patch_branch, status: "applied", pushed_at: nil, ci_status: "push_failed",
                            updated_at: 1.minute.ago)

      expect(items_of(:backfill)).to be_empty
    end

    it "emits one row per topic" do
      topic = create(:topic)
      older = create(:patch_branch, topic: topic, status: "applied", pushed_at: nil,
                                    message: create(:message, topic: topic, created_at: 9.days.ago))
      create(:patch_branch, topic: topic, status: "applied", pushed_at: nil,
                            message: create(:message, topic: topic, created_at: 2.days.ago))

      items = items_of(:backfill)

      expect(items.size).to eq(1)
      expect(items.first.patch_branch).not_to eq(older)
    end

    it "does not emit ci_none rows" do
      create(:patch_branch, status: "applied", pushed_at: nil, ci_status: "ci_none")

      expect(items_of(:backfill)).to be_empty
    end

    it "does not emit committed topics" do
      topic = create(:topic)
      create(:patch_branch, topic: topic, status: "applied", pushed_at: nil)
      create(:commit_topic, topic: topic)

      expect(items_of(:backfill)).to be_empty
    end

    it "does not emit superseded rows" do
      newer = create(:patch_branch)
      create(:patch_branch, status: "applied", pushed_at: nil, superseded_by_id: newer.id)

      expect(items_of(:backfill).map(&:patch_branch)).to eq([ newer ])
    end

    it "orders newest message first" do
      old_row = create(:patch_branch, status: "applied", pushed_at: nil,
                                     message: create(:message, created_at: 9.days.ago))
      new_row = create(:patch_branch, status: "applied", pushed_at: nil,
                                      message: create(:message, created_at: 2.days.ago))

      expect(items_of(:backfill).map(&:patch_branch)).to eq([ new_row, old_row ])
    end
  end

  describe "tier 3 rebase" do
    def active_topic = create(:topic, last_message_at: 1.day.ago)

    def pushed_row(topic, **attrs)
      create(:patch_branch, { topic: topic, status: "applied", pushed_at: 1.day.ago,
                              base_committed_at: 100.days.ago }.merge(attrs))
    end

    it "emits stale pushed rows stalest first" do
      fresher = pushed_row(active_topic, base_committed_at: 60.days.ago)
      stalest = pushed_row(active_topic, base_committed_at: 200.days.ago)

      expect(items_of(:rebase).map(&:patch_branch)).to eq([ stalest, fresher ])
    end

    it "emits rows with a nil base_committed_at" do
      row = pushed_row(active_topic, base_committed_at: nil)

      expect(items_of(:rebase).map(&:patch_branch)).to eq([ row ])
    end

    it "orders equally aged nil base_committed_at rows by id" do
      attempted_at = 3.days.ago
      first = pushed_row(active_topic, base_committed_at: nil, last_master_apply_at: attempted_at)
      second = pushed_row(active_topic, base_committed_at: nil, last_master_apply_at: attempted_at)

      expect(items_of(:rebase).map(&:patch_branch)).to eq([ first, second ])
    end

    it "puts the least recently attempted row first, even if its base is fresher" do
      just_tried = pushed_row(active_topic, base_committed_at: 200.days.ago,
                                            last_master_apply_at: 1.hour.ago)
      long_untried = pushed_row(active_topic, base_committed_at: 60.days.ago,
                                              last_master_apply_at: 5.days.ago)

      expect(items_of(:rebase).map(&:patch_branch)).to eq([ long_untried, just_tried ])
    end

    it "puts never attempted rows ahead of attempted ones" do
      attempted = pushed_row(active_topic, base_committed_at: 200.days.ago,
                                           last_master_apply_at: 5.days.ago)
      never = pushed_row(active_topic, base_committed_at: 60.days.ago, last_master_apply_at: nil)

      expect(items_of(:rebase).map(&:patch_branch)).to eq([ never, attempted ])
    end

    it "emits rows with a master_apply_error even when the base is fresh" do
      row = pushed_row(active_topic, base_committed_at: 1.day.ago,
                                     master_apply_error: "conflict in src/backend")

      expect(items_of(:rebase).map(&:patch_branch)).to eq([ row ])
    end

    it "does not emit rows with ci in flight" do
      pushed_row(active_topic, ci_status: "running")

      expect(items_of(:rebase)).to be_empty
    end

    it "emits rows whose ci already reached a verdict" do
      row = pushed_row(active_topic, ci_status: "success")

      expect(items_of(:rebase).map(&:patch_branch)).to eq([ row ])
    end

    it "emits rows whose run was marked infra_error" do
      row = pushed_row(active_topic, ci_status: "infra_error")

      expect(items_of(:rebase).map(&:patch_branch)).to eq([ row ])
    end

    it "does not emit fresh pushed rows" do
      pushed_row(active_topic, base_committed_at: 1.day.ago)

      expect(items_of(:rebase)).to be_empty
    end

    it "does not emit rows on inactive topics" do
      stale_topic = create(:topic)
      pushed_row(stale_topic)
      # creating the row's message bumps last_message_at, so age the thread after
      stale_topic.update_column(:last_message_at, 90.days.ago)

      expect(items_of(:rebase)).to be_empty
    end

    it "does not emit rows on committed topics even when the thread is active" do
      topic = active_topic
      pushed_row(topic)
      create(:commit_topic, topic: topic)

      expect(items_of(:rebase)).to be_empty
      expect(planner.counts[:rebase]).to eq(0)
    end

    it "does not emit rows on merged topics even when the thread is active" do
      topic = active_topic
      pushed_row(topic)
      topic.update!(merged_into_topic_id: create(:topic).id)

      expect(items_of(:rebase)).to be_empty
      expect(planner.counts[:rebase]).to eq(0)
    end

    it "emits failed never-pushed rows whose failure_stage is apply" do
      row = create(:patch_branch, topic: active_topic, status: "failed",
                                  failure_stage: "apply", pushed_at: nil)

      expect(items_of(:rebase).map(&:patch_branch)).to eq([ row ])
    end

    it "does not emit failed rows whose failure_stage is extract" do
      create(:patch_branch, topic: active_topic, status: "failed",
                            failure_stage: "extract", pushed_at: nil)

      expect(items_of(:rebase)).to be_empty
    end

    describe "retry guard" do
      it "excludes rows already retried against the current master" do
        pushed_row(active_topic, last_master_apply_at: master_at)

        expect(items_of(:rebase)).to be_empty
      end

      it "re-includes them once master moves forward" do
        row = pushed_row(active_topic, last_master_apply_at: master_at)
        repo_state.update!(master_committed_at: master_at + 1.hour)

        expect(items_of(:rebase).map(&:patch_branch)).to eq([ row ])
      end
    end
  end

  describe "priority and limits" do
    def one_of_each
      new_version_topic = create(:topic)
      patch_message(new_version_topic)
      create(:patch_branch, status: "applied", pushed_at: nil, ci_status: nil)
      create(:patch_branch, topic: create(:topic, last_message_at: 1.day.ago),
                            status: "applied", pushed_at: 1.day.ago,
                            base_committed_at: 100.days.ago)
    end

    it "orders tiers new_version, backfill, rebase" do
      one_of_each

      expect(kinds_of(planner.plan)).to eq([ :new_version, :backfill, :rebase ])
    end

    it "counts every tier" do
      one_of_each

      expect(planner.counts).to eq(new_version: 1, backfill: 1, rebase: 1)
    end

    describe "per-topic dedupe" do
      # topic with a stale pushed row AND a newer rowless patch message
      def topic_in_two_tiers
        topic = create(:topic, last_message_at: 1.day.ago)
        create(:patch_branch, topic: topic, status: "applied", pushed_at: 1.day.ago,
                              base_committed_at: 100.days.ago)
        patch_message(topic, created_at: 1.day.ago)
        topic
      end

      it "keeps only the highest tier for a topic" do
        topic = topic_in_two_tiers

        items = planner.plan

        expect(kinds_of(items)).to eq([ :new_version ])
        expect(items.first.message.topic_id).to eq(topic.id)
      end

      it "still spends the limit on other topics, not on the dropped row" do
        topic_in_two_tiers
        other = create(:topic, last_message_at: 1.day.ago)
        rebase_row = create(:patch_branch, topic: other, status: "applied", pushed_at: 1.day.ago,
                                           base_committed_at: 200.days.ago)

        items = planner.plan(limit: 2)

        expect(kinds_of(items)).to eq([ :new_version, :rebase ])
        expect(items.last.patch_branch).to eq(rebase_row)
      end

      it "leaves counts as raw per-tier totals that may overlap topics" do
        topic_in_two_tiers

        expect(planner.counts).to eq(new_version: 1, backfill: 0, rebase: 1)
      end
    end

    it "fills the limit from the top tier only" do
      3.times { |i| patch_message(create(:topic), created_at: (i + 1).days.ago) }
      one_of_each

      items = planner.plan(limit: 2)

      expect(kinds_of(items)).to eq([ :new_version, :new_version ])
      expect(planner.counts[:new_version]).to eq(4)
    end

    it "does not build lower tiers once the limit is full" do
      3.times { |i| patch_message(create(:topic), created_at: (i + 1).days.ago) }
      one_of_each
      subject_planner = planner

      expect(PatchBranch).not_to receive(:current)

      expect(subject_planner.plan(limit: 2).size).to eq(2)
    end

    it "defaults the limit to the up next list size" do
      stub_const("PatchCi::Config::UP_NEXT_LIST", 1)
      3.times { |i| patch_message(create(:topic), created_at: (i + 1).days.ago) }

      expect(planner.plan.size).to eq(1)
    end

    it "spills into lower tiers when the top tier is short" do
      one_of_each

      expect(kinds_of(planner.plan(limit: 2))).to eq([ :new_version, :backfill ])
    end

    it "preloads the topic of every item message" do
      one_of_each

      planner.plan.each do |item|
        expect(item.message.association(:topic)).to be_loaded
        expect(item.message.topic).to be_present
      end
    end
  end

  describe "work item helpers" do
    it "answers topic_id and topic from the message when there is no row" do
      topic = create(:topic)
      patch_message(topic)

      item = items_of(:new_version).first

      expect(item.topic_id).to eq(topic.id)
      expect(item.topic).to eq(topic)
    end

    it "answers topic_id and topic for branch backed items" do
      row = create(:patch_branch, status: "applied", pushed_at: nil)

      item = items_of(:backfill).first

      expect(item.topic_id).to eq(row.topic_id)
      expect(item.topic).to eq(row.topic)
    end
  end

  describe "without a repo state" do
    subject(:no_state) { described_class.new(repo_state: nil) }

    it "plans nothing" do
      patch_message(create(:topic))

      expect(no_state.plan).to eq([])
      expect(no_state.counts).to eq(new_version: 0, backfill: 0, rebase: 0)
    end
  end
end
