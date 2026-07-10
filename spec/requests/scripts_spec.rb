# frozen_string_literal: true

require 'rails_helper'

RSpec.describe "Scripts", type: :request do
  describe "GET /scripts/:name/version" do
    it "returns changelog for a known script" do
      get script_version_path("hackorum-patch")

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to be_a(Enumerable)
    end

    it "returns 404 for an unknown script" do
      get script_version_path("nope")

      expect(response).to have_http_status(:not_found)
    end

    it "rejects names with path traversal characters" do
      get "/scripts/..%2F..%2Fconfig%2Fmaster/version"

      expect(response).to have_http_status(:not_found)
    end
  end
end
