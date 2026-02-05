# frozen_string_literal: true

require 'rails_helper'

RSpec.describe "Admin::EmailChanges", type: :request do
  def sign_in(email:, password: "secret")
    post session_path, params: { email: email, password: password }
    expect(response).to redirect_to(root_path)
  end

  def attach_verified_alias(user, email:)
    al = create(:alias, user: user, email: email)
    user.person.update!(default_alias_id: al.id) if user.person&.default_alias_id.nil?
    Alias.by_email(email).update_all(verified_at: Time.current)
    al
  end

  let!(:admin) { create(:user, password: "secret", password_confirmation: "secret", admin: true, username: "admin_user") }

  before do
    attach_verified_alias(admin, email: "admin@example.com")
  end

  describe "access control" do
    it "redirects unauthenticated users" do
      get admin_email_changes_path
      expect(response).to redirect_to(root_path)
    end

    it "redirects non-admin users" do
      regular = create(:user, password: "secret", password_confirmation: "secret", admin: false)
      attach_verified_alias(regular, email: "regular@example.com")
      sign_in(email: "regular@example.com")
      get admin_email_changes_path
      expect(response).to redirect_to(root_path)
    end
  end

  describe "GET /admin/email_changes" do
    before { sign_in(email: "admin@example.com") }

    it "renders the audit log page" do
      get admin_email_changes_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Email Change Audit Log")
    end

    it "renders empty state when no records exist" do
      get admin_email_changes_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("No email associations have been performed yet")
    end

    it "displays log entries with correct data" do
      target = create(:user, username: "target_user")
      attach_verified_alias(target, email: "target@example.com")

      AdminEmailChange.create!(
        performed_by: admin,
        target_user: target,
        email: "new@example.com",
        aliases_attached: 0,
        created_new_alias: true
      )

      AdminEmailChange.create!(
        performed_by: admin,
        target_user: target,
        email: "existing@example.com",
        aliases_attached: 3,
        created_new_alias: false
      )

      get admin_email_changes_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("new@example.com")
      expect(response.body).to include("existing@example.com")
      expect(response.body).to include("New alias created")
      expect(response.body).to include("3 existing aliases attached")
      expect(response.body).to include("admin_user")
      expect(response.body).to include("target_user")
    end
  end
end
