require 'rails_helper'

RSpec.describe 'OmniAuth setup proc' do
  let(:strategy) { double('OmniAuth::Strategy', options: options) }
  let(:env)      { { "omniauth.strategy" => strategy } }
  let(:options)  { OmniAuth::Strategy::Options.new }

  before do
    # The setup proc is stored as an Rails-level constant so we can call it directly.
  end

  context 'with send=1 in request params' do
    it 'uses gmail.send scope, offline access_type, consent prompt' do
      env_with_query = env.merge("QUERY_STRING" => "send=1")
      OMNIAUTH_SETUP_PROC.call(env_with_query)
      expect(options[:scope]).to       include('gmail.send')
      expect(options[:access_type]).to eq('offline')
      expect(options[:prompt]).to eq('consent')
    end
  end

  context 'without send=1' do
    it 'uses email/profile, online access_type, select_account prompt' do
      env_with_query = env.merge("QUERY_STRING" => "")
      OMNIAUTH_SETUP_PROC.call(env_with_query)
      expect(options[:scope]).to       eq('email,profile')
      expect(options[:access_type]).to eq('online')
      expect(options[:prompt]).to eq('select_account')
    end
  end
end
