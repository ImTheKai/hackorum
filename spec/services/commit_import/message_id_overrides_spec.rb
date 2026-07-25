require "rails_helper"

RSpec.describe CommitImport::MessageIdOverrides do
  describe ".apply" do
    it "returns a known-bad id corrected" do
      key, value = described_class::MAP.first
      expect(described_class.apply(key)).to eq(value)
    end

    it "passes an unknown id through untouched" do
      expect(described_class.apply("abc@x")).to eq("abc@x")
    end
  end

  describe "MAP" do
    it "never maps an id to itself" do
      expect(described_class::MAP.select { |k, v| k == v }).to be_empty
    end

    it "corrects to something that looks like a message id" do
      expect(described_class::MAP.values.reject { |v| v.include?("@") }).to be_empty
    end

    it "stores keys in the form the parser produces" do
      described_class::MAP.each_key do |key|
        expect(MessageIdNormalizer.normalize(key)).to eq(key)
      end
    end
  end
end
