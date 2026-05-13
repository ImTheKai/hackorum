require 'rails_helper'

RSpec.describe Outgoing::RecipientResolver do
  let(:list)  { create(:mailing_list, post_address: "real@list.example") }
  let(:topic) { create(:topic, mailing_lists: [ list ]) }

  context 'in production' do
    before { allow(Rails.env).to receive(:production?).and_return(true) }

    it 'returns the post_address' do
      expect(described_class.for(topic)).to eq("real@list.example")
    end

    it 'raises MissingPostAddressError when blank' do
      list.update!(post_address: nil)
      expect { described_class.for(topic) }
        .to raise_error(Outgoing::RecipientResolver::MissingPostAddressError)
    end

    it 'raises MissingPostAddressError when topic has no mailing list' do
      topic.mailing_lists.clear
      expect { described_class.for(topic) }
        .to raise_error(Outgoing::RecipientResolver::MissingPostAddressError)
    end
  end

  context 'in development' do
    it 'returns the override' do
      with_env('HACKORUM_DEV_REPLY_TO' => 'test@example.com') do
        expect(described_class.for(topic)).to eq('test@example.com')
      end
    end

    it 'raises MissingDevOverrideError when override blank' do
      with_env('HACKORUM_DEV_REPLY_TO' => nil) do
        expect { described_class.for(topic) }
          .to raise_error(Outgoing::RecipientResolver::MissingDevOverrideError)
      end
    end

    it 'raises MissingDevOverrideError when override is empty string' do
      with_env('HACKORUM_DEV_REPLY_TO' => '') do
        expect { described_class.for(topic) }
          .to raise_error(Outgoing::RecipientResolver::MissingDevOverrideError)
      end
    end

    it 'raises RealListAddressInDevError when override matches a real list (case-insensitive)' do
      with_env('HACKORUM_DEV_REPLY_TO' => 'REAL@list.example') do
        expect { described_class.for(topic) }
          .to raise_error(Outgoing::RecipientResolver::RealListAddressInDevError)
      end
    end

    it 'returns the override even when the topic has no mailing list with post_address' do
      list.update!(post_address: nil)
      with_env('HACKORUM_DEV_REPLY_TO' => 'test@example.com') do
        expect(described_class.for(topic)).to eq('test@example.com')
      end
    end

    it 'returns the override for topics with no mailing list at all' do
      orphan_topic = create(:topic)
      with_env('HACKORUM_DEV_REPLY_TO' => 'test@example.com') do
        expect(described_class.for(orphan_topic)).to eq('test@example.com')
      end
    end
  end
end
