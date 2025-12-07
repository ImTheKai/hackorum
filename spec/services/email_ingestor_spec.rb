require "rails_helper"

RSpec.describe EmailIngestor do
  describe "#normalize_subject_for_threading" do
    it "strips prefixes, list tags, and (fwd)" do
      ingestor = described_class.new
      normalized = ingestor.send(:normalize_subject_for_threading, "Re: [HACKERS] Re: [PORTS] (fwd) Topic ABC")
      expect(normalized).to eq("topic abc")
    end
  end

  describe "#fallback_thread_lookup" do
    let!(:topic) { create(:topic) }
    let!(:root_msg) { create(:message, topic: topic, subject: "Anyone working on linux Alpha?", created_at: 2.days.ago) }
    let!(:root_aw) { create(:message, topic: topic, subject: "mmap and MAP_ANON", created_at: 2.days.ago) }
    let(:ingestor) { described_class.new }

    it "matches subjects with multiple prefixes and list tags" do
      subject = "Re: [HACKERS] Re: [PORTS] Anyone working on linux Alpha?"
      found = ingestor.send(:fallback_thread_lookup, subject, message_id: nil, references: [], sent_at: Time.current)
      expect(found).to eq(root_msg)
    end

    it "matches AW prefix with list tags to plain subject" do
      subject = "AW: [HACKERS] mmap and MAP_ANON"
      found = ingestor.send(:fallback_thread_lookup, subject, message_id: nil, references: [], sent_at: Time.current)
      expect(found).to eq(root_aw)
    end
  end
end
