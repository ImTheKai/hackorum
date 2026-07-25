require "rails_helper"

RSpec.describe "Topic index commit icon", type: :request do
  it "renders the commit icon for a topic with commits" do
    topic = create(:topic, :with_messages)
    commit = create(:commit, subject: "Fix the executor", branches: [ "REL_18_STABLE" ], released_in: "18.5")
    create(:commit_topic, commit: commit, topic: topic)
    topic.update_columns(commit_count: 1)

    get root_path

    expect(response.body).to include("commit-icon")
    expect(response.body).to include("Fix the executor")
    expect(response.body).to include("18.5")
  end

  it "does not render the commit icon for a topic without commits" do
    create(:topic, :with_messages)

    get root_path

    expect(response.body).not_to include("commit-icon")
  end

  it "shows unreleased commits as unreleased" do
    topic = create(:topic, :with_messages)
    commit = create(:commit, branches: [ "master" ], released_in: nil)
    create(:commit_topic, commit: commit, topic: topic)
    topic.update_columns(commit_count: 1)

    get root_path

    expect(response.body).to include("unreleased")
  end

  it "counts a backported change once in the popover header, not once per commit" do
    topic = create(:topic, :with_messages)
    canonical = create(:commit, sha: "ppp1", subject: "Shared change", branches: [ "master" ],
                                committed_at: 3.days.ago)
    backport_17 = create(:commit, sha: "qqq2", subject: "Shared change", branches: [ "REL_17_STABLE" ],
                                  released_in: "17.4", cherry_picked_from_sha: "ppp1",
                                  committed_at: 2.days.ago)
    backport_18 = create(:commit, sha: "rrr3", subject: "Shared change", branches: [ "REL_18_STABLE" ],
                                  released_in: "18.5", cherry_picked_from_sha: "ppp1",
                                  committed_at: 1.day.ago)
    create(:commit_topic, commit: canonical, topic: topic)
    create(:commit_topic, commit: backport_17, topic: topic)
    create(:commit_topic, commit: backport_18, topic: topic)
    topic.update_columns(commit_count: 3)

    get root_path

    expect(response.body).to include(">1 commit<")
    expect(response.body).not_to include(">3 commit<")
  end

  it "caps the popover at 5 entries and shows a +N more note" do
    topic = create(:topic, :with_messages)
    7.times do |i|
      commit = create(:commit, subject: "Change #{i}", committed_at: (7 - i).days.ago)
      create(:commit_topic, commit: commit, topic: topic)
    end
    topic.update_columns(commit_count: 7)

    get root_path

    # status cell renders the icon markup twice (desktop + mobile layout),
    # so 5 capped entries and the "+2 more" note each show up twice.
    expect(response.body.scan("commit-hover-entry").size).to eq(10)
    expect(response.body.scan("+2 more").size).to eq(2)
  end
end
