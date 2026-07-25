require "rails_helper"

RSpec.describe "removed patch submissions endpoint", type: :routing do
  it "no longer routes" do
    expect(get: "/patch_submissions.json").not_to be_routable
  end
end
