require "rails_helper"

RSpec.describe ReleaseTag do
  describe ".normalize" do
    {
      "REL_18_5" => "18.5",
      "REL_19_0" => "19.0",
      "REL_19_BETA1" => "19beta1",
      "REL_19_RC1" => "19rc1",
      "REL9_5_2" => "9.5.2",
      "REL9_6_BETA2" => "9.6beta2",
      "REL_18_STABLE" => nil,
      "junk" => nil
    }.each do |name, expected|
      it "maps #{name} to #{expected.inspect}" do
        expect(described_class.normalize(name)).to eq(expected)
      end
    end
  end
end
