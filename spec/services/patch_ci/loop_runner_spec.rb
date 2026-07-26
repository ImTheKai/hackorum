require "rails_helper"

RSpec.describe PatchCi::LoopRunner do
  let(:client) { instance_double(PatchCi::GithubClient) }
  let(:pusher) { instance_double(PatchCi::Pusher) }
  let(:selector) { instance_double(PatchCi::PushCandidateSelector, rejections: {}) }
  let(:fetch_result) { instance_double(PatchBranches::GitRepo::Result, success?: true) }
  let(:refs) { instance_double(PatchCi::ResultRefs, fetch!: fetch_result, payloads: {}) }

  def runner(budget: 18)
    described_class.new(client: client, pusher: pusher, selector: selector,
                        result_refs: refs, budget: budget)
  end

  it "pushes up to the free slots" do
    rows = Array.new(3) { create(:patch_branch) }
    allow(client).to receive(:runs).and_return([])
    allow(client).to receive(:in_flight_count).and_return(0)
    allow(selector).to receive(:eligible).and_return(rows)
    expect(pusher).to receive(:push).exactly(3).times.and_return(true)

    result = runner(budget: 5).cycle

    expect(result[:pushed]).to eq(3)
    expect(result[:free_slots]).to eq(5)
  end

  it "pushes nothing when the budget is full" do
    allow(client).to receive(:runs).and_return([])
    allow(client).to receive(:in_flight_count).and_return(18)
    allow(selector).to receive(:eligible).and_return([ create(:patch_branch) ])
    expect(pusher).not_to receive(:push)

    expect(runner.cycle[:free_slots]).to eq(0)
  end

  it "pushes nothing when the API call fails" do
    allow(client).to receive(:runs).and_raise(PatchCi::GithubClient::Error, "403")
    expect(pusher).not_to receive(:push)
    expect(selector).not_to receive(:eligible)

    result = runner.cycle

    expect(result[:pushed]).to eq(0)
    expect(result[:error]).to include("403")
  end

  it "pushes nothing when in_flight_count fails" do
    allow(client).to receive(:runs).and_return([])
    allow(client).to receive(:in_flight_count).and_raise(PatchCi::GithubClient::Error, "rate limited")
    expect(pusher).not_to receive(:push)
    expect(selector).not_to receive(:eligible)

    result = runner.cycle

    expect(result[:pushed]).to eq(0)
    expect(result[:error]).to include("rate limited")
  end

  it "never reports negative free slots" do
    allow(client).to receive(:runs).and_return([])
    allow(client).to receive(:in_flight_count).and_return(25)
    allow(selector).to receive(:eligible).and_return([])

    expect(runner.cycle[:free_slots]).to eq(0)
  end

  it "records rejections" do
    row = create(:patch_branch)
    allow(client).to receive(:runs).and_return([])
    allow(client).to receive(:in_flight_count).and_return(0)
    allow(selector).to receive(:eligible).and_return([])
    allow(selector).to receive(:rejections).and_return({ row.id => "no era image for pg16" })
    expect(pusher).to receive(:skip).with(an_object_having_attributes(id: row.id), "no era image for pg16")

    expect(runner.cycle[:skipped]).to eq(1)
  end

  it "skips ingestion and flags refs_stale when the fetch fails" do
    allow(client).to receive(:runs).and_return([])
    allow(client).to receive(:in_flight_count).and_return(0)
    allow(selector).to receive(:eligible).and_return([])
    allow(fetch_result).to receive(:success?).and_return(false)
    expect(refs).not_to receive(:payloads)

    result = runner.cycle

    expect(result[:refs_stale]).to eq(true)
    expect(result[:ingested]).to eq({})
    expect(result[:error]).to be_nil
  end
end
