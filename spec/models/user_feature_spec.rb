require "rails_helper"

RSpec.describe UserFeature do
  let(:user) { create(:user) }

  it "is valid with a known feature name" do
    expect(build(:user_feature, user: user, feature: "email_sending")).to be_valid
  end

  it "is invalid with an unknown feature name" do
    uf = build(:user_feature, user: user, feature: "bogus")
    expect(uf).not_to be_valid
    expect(uf.errors[:feature]).to be_present
  end

  it "is invalid without a feature" do
    uf = build(:user_feature, user: user, feature: nil)
    expect(uf).not_to be_valid
  end

  it "enforces uniqueness per (user, feature)" do
    create(:user_feature, user: user, feature: "email_sending")
    dup = build(:user_feature, user: user, feature: "email_sending")
    expect(dup).not_to be_valid
  end
end
