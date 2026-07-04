require "rails_helper"
require "cgi"

RSpec.describe "Commit linking read APIs", type: :request do
  describe "by-id json" do
    it "resolves an existing message-id to its topic as JSON" do
      topic = create(:topic, title: "Add a widget")
      list  = create(:mailing_list, identifier: "pgsql-hackers")
      topic.mailing_lists << list
      msg = create(:message, topic: topic, message_id: "abc123@example.com")

      get "/messages/by-id/#{CGI.escape(msg.message_id)}.json"

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["topic_id"]).to eq(topic.id)
      expect(body["topic_title"]).to eq("Add a widget")
      expect(body["mailing_lists"]).to include("pgsql-hackers")
      expect(body["message_id"]).to eq("abc123@example.com")
    end

    it "returns 404 JSON for an unknown message-id" do
      get "/messages/by-id/nope@example.com.json"
      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)).to have_key("error")
    end

    it "round-trips a message-id containing + and other special characters" do
      mid = "CAJ7c6TPDOY+vfkmTF5Q@mail.gmail.com"
      topic = create(:topic, title: "Special chars topic")
      msg = create(:message, topic: topic, message_id: mid)

      get "/messages/by-id/#{CGI.escape(mid)}.json"

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["message_id"]).to eq(mid)
    end
  end
end
