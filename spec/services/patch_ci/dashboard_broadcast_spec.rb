require "rails_helper"

RSpec.describe PatchCi::DashboardBroadcast do
  it "broadcasts a refresh to the dashboard stream" do
    expect(Turbo::StreamsChannel).to receive(:broadcast_refresh_to).with("ci_dashboard")
    described_class.refresh!
  end
end

RSpec.describe "dashboard subscription", type: :request do
  it "subscribes to the ci_dashboard stream and morphs on refresh" do
    get "/ci"

    expect(response.body).to include("turbo-cable-stream-source")
    expect(response.body).to include('name="turbo-refresh-method" content="morph"')
    expect(response.body).to include('name="turbo-refresh-scroll" content="preserve"')
  end
end
