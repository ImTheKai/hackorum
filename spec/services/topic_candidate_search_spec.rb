require "rails_helper"

RSpec.describe TopicCandidateSearch do
  let(:hackers) { create(:mailing_list, identifier: "pgsql-hackers", display_name: "pgsql-hackers") }
  let(:bugs)    { create(:mailing_list, identifier: "pgsql-bugs", display_name: "pgsql-bugs") }

  def topic_with(title:, list:, created_at:, body: "hello", patch: false)
    topic = create(:topic, title: title, created_at: created_at, last_message_at: created_at)
    topic.mailing_lists << list
    create(:message, topic: topic, body: body, created_at: created_at, is_patch_submission: patch)
    topic
  end

  it "matches on title text within the date window" do
    hit  = topic_with(title: "Improve vacuum throttling", list: hackers, created_at: 10.days.ago)
    _miss_text = topic_with(title: "Unrelated docs change", list: hackers, created_at: 10.days.ago)
    _miss_date = topic_with(title: "Improve vacuum throttling", list: hackers, created_at: 2.years.ago)

    results = described_class.new(
      q: "vacuum throttling", from: 30.days.ago, to: Time.current,
      mailing_lists: [], patches_only: false, limit: 10
    ).results

    expect(results.map(&:id)).to include(hit.id)
    expect(results.map(&:id)).not_to include(_miss_date.id)
  end

  it "restricts to patch-submission threads when patches_only" do
    patchy = topic_with(title: "Add widget patch", list: hackers, created_at: 5.days.ago, patch: true)
    plain  = topic_with(title: "Add widget discussion", list: hackers, created_at: 5.days.ago, patch: false)

    results = described_class.new(
      q: "widget", from: 30.days.ago, to: Time.current,
      mailing_lists: [], patches_only: true, limit: 10
    ).results

    expect(results.map(&:id)).to include(patchy.id)
    expect(results.map(&:id)).not_to include(plain.id)
  end

  it "filters by mailing list identifier" do
    on_bugs = topic_with(title: "crash report widget", list: bugs, created_at: 5.days.ago)
    _on_hackers = topic_with(title: "crash report widget", list: hackers, created_at: 5.days.ago)

    results = described_class.new(
      q: "crash widget", from: 30.days.ago, to: Time.current,
      mailing_lists: ["pgsql-bugs"], patches_only: false, limit: 10
    ).results

    expect(results.map(&:id)).to eq([on_bugs.id])
  end

  it "sets has_patches based on patch-submission messages, not attachments" do
    with_patch    = topic_with(title: "patch submission topic", list: hackers, created_at: 5.days.ago, patch: true)
    without_patch = topic_with(title: "no patch topic", list: hackers, created_at: 5.days.ago, patch: false)

    results = described_class.new(
      q: "", from: 30.days.ago, to: Time.current,
      mailing_lists: [], patches_only: false, limit: 10
    ).results

    patch_result    = results.find { |r| r.id == with_patch.id }
    no_patch_result = results.find { |r| r.id == without_patch.id }

    expect(patch_result.has_patches).to eq(true)
    expect(no_patch_result.has_patches).to eq(false)
  end

  it "returns a non-zero score for a topic whose title strongly matches the query" do
    hit = topic_with(title: "vacuum autovacuum freezing strategy", list: hackers, created_at: 5.days.ago)

    results = described_class.new(
      q: "vacuum freezing", from: 30.days.ago, to: Time.current,
      mailing_lists: [], patches_only: false, limit: 10
    ).results

    result = results.find { |r| r.id == hit.id }
    expect(result).not_to be_nil
    expect(result.score).to be > 0.0
  end

  describe "one-sided date ranges" do
    it "from: only returns topics on/after from and excludes older ones" do
      recent = topic_with(title: "recent index scan", list: hackers, created_at: 5.days.ago)
      old    = topic_with(title: "old index scan",    list: hackers, created_at: 60.days.ago)

      results = described_class.new(
        q: "index scan", from: 30.days.ago, to: nil,
        mailing_lists: [], patches_only: false, limit: 10
      ).results

      expect(results.map(&:id)).to include(recent.id)
      expect(results.map(&:id)).not_to include(old.id)
    end

    it "to: only excludes topics newer than to" do
      old    = topic_with(title: "old buffer pool",    list: hackers, created_at: 60.days.ago)
      recent = topic_with(title: "recent buffer pool", list: hackers, created_at: 5.days.ago)

      results = described_class.new(
        q: "buffer pool", from: nil, to: 30.days.ago,
        mailing_lists: [], patches_only: false, limit: 10
      ).results

      expect(results.map(&:id)).to include(old.id)
      expect(results.map(&:id)).not_to include(recent.id)
    end
  end

  describe "limit clamping" do
    it "limit: 0 is clamped to 1 and returns at most 1 result" do
      topic_with(title: "wal writer optimization", list: hackers, created_at: 5.days.ago)
      topic_with(title: "wal writer performance",  list: hackers, created_at: 4.days.ago)

      results = described_class.new(
        q: "wal writer", from: 30.days.ago, to: Time.current,
        mailing_lists: [], patches_only: false, limit: 0
      ).results

      expect(results.size).to eq(1)
    end

    it "limit: 999 is clamped to MAX_LIMIT and does not raise" do
      topic_with(title: "checkpoint tuning alpha", list: hackers, created_at: 5.days.ago)
      topic_with(title: "checkpoint tuning beta",  list: hackers, created_at: 4.days.ago)

      expect {
        described_class.new(
          q: "checkpoint tuning", from: 30.days.ago, to: Time.current,
          mailing_lists: [], patches_only: false, limit: 999
        ).results
      }.not_to raise_error
    end
  end

  it "returns the first message body as the snippet after moving to subquery" do
    topic = topic_with(
      title: "replication slot improvements",
      list: hackers,
      created_at: 5.days.ago,
      body: "This patch improves replication slot cleanup"
    )

    results = described_class.new(
      q: "replication slot", from: 30.days.ago, to: Time.current,
      mailing_lists: [], patches_only: false, limit: 10
    ).results

    result = results.find { |r| r.id == topic.id }
    expect(result).not_to be_nil
    expect(result.first_message_snippet).to include("This patch improves replication slot cleanup")
  end
end
