require "rails_helper"

RSpec.describe "Messages", type: :request do
  describe "GET /messages/:id/patchset" do
    let!(:creator) { create(:alias) }
    let!(:topic)   { create(:topic, creator: creator) }

    context "with a patch-submission message" do
      let!(:message) do
        create(:message, topic: topic, sender: creator, created_at: 1.hour.ago)
      end
      let!(:patch) do
        create(:attachment, :patch_file, message: message, file_name: "v1.patch")
      end

      it "returns the per-message patchset tar.gz" do
        get message_patchset_path(message)

        expect(response).to have_http_status(:ok)
        expect(response.content_type).to eq("application/gzip")
        expect(response.headers["Content-Disposition"]).to include("attachment")
        expect(response.headers["Content-Disposition"]).to include(
          "topic-#{topic.id}-msg1-patchset.tar.gz"
        )
      end
    end

    context "with a message that is not a patch submission" do
      let!(:message) { create(:message, topic: topic, sender: creator) }

      it "returns 404" do
        get message_patchset_path(message)
        expect(response).to have_http_status(:not_found)
      end
    end

    context "with a nonexistent message" do
      it "returns 404" do
        get message_patchset_path(id: 99999)
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
