# frozen_string_literal: true

require 'rails_helper'

RSpec.describe "Admin::Dashboard", type: :request do
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

  describe "GET /admin" do
    it "redirects non-admin users" do
      user = create(:user, password: "secret", password_confirmation: "secret", admin: false)
      attach_verified_alias(user, email: "user@example.com")
      sign_in(email: "user@example.com")

      get admin_root_path
      expect(response).to redirect_to(root_path)
    end

    it "redirects unauthenticated users" do
      get admin_root_path
      expect(response).to redirect_to(root_path)
    end

    it "renders for admin users" do
      admin = create(:user, password: "secret", password_confirmation: "secret", admin: true)
      attach_verified_alias(admin, email: "admin@example.com")
      sign_in(email: "admin@example.com")

      get admin_root_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Admin Dashboard")
    end
  end
end
