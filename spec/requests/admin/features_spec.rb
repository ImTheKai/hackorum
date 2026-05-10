require "rails_helper"

RSpec.describe "Admin::Features", type: :request do
  let(:admin) { create(:user, admin: true) }

  before { sign_in_as(admin) }

  describe "GET /admin/features" do
    it "lists all features with enrollment counts" do
      target = create(:user)
      create(:user_feature, user: target, feature: "email_sending")
      get admin_features_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Email sending")
    end

    it "rejects non-admins" do
      sign_in_as(create(:user))
      get admin_features_path
      expect(response).to have_http_status(:found)
    end
  end

  describe "GET /admin/features/:name" do
    it "shows enrolled users" do
      target = create(:user, username: "bob")
      create(:user_feature, user: target, feature: "email_sending")
      get admin_feature_path("email_sending")
      expect(response.body).to include("bob")
    end

    it "404s on unknown feature" do
      get admin_feature_path("bogus")
      expect(response.status).to eq(404)
    end
  end

  describe "POST /admin/features/:name/enrollments" do
    it "enrolls a user by username" do
      target = create(:user, username: "charlie")
      post admin_feature_enrollments_path("email_sending"), params: { identifier: "charlie" }
      expect(target.reload.user_features.where(feature: "email_sending")).to exist
    end

    it "enrolls a user by email" do
      target = create(:user)
      al = create(:alias, user: target, person: target.person, email: "dee@example.com")
      target.person.update!(default_alias_id: al.id)
      post admin_feature_enrollments_path("email_sending"), params: { identifier: "dee@example.com" }
      expect(target.reload.user_features.where(feature: "email_sending")).to exist
    end

    it "matches a mixed-case email regardless of stored case" do
      target = create(:user)
      create(:alias, user: target, person: target.person, email: "Eve@Example.COM")
      post admin_feature_enrollments_path("email_sending"), params: { identifier: "eve@example.com" }
      expect(target.reload.user_features.where(feature: "email_sending")).to exist
    end

    it "reports an error when identifier matches no user" do
      post admin_feature_enrollments_path("email_sending"), params: { identifier: "nobody@nowhere" }
      expect(flash[:alert]).to be_present
    end
  end

  describe "DELETE /admin/features/:name/enrollments/:user_id" do
    it "removes the enrollment" do
      target = create(:user)
      create(:user_feature, user: target, feature: "email_sending")
      delete admin_feature_enrollment_path("email_sending", target)
      expect(target.user_features.where(feature: "email_sending")).not_to exist
    end
  end
end
