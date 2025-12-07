require 'rails_helper'

RSpec.describe Alias, type: :model do
  describe '.by_email' do
    it 'matches case-insensitively and trims spaces' do
      create(:alias, email: 'User@Example.com')
      expect(Alias.by_email(' user@example.com ')).to exist
    end
  end

  describe 'primary alias invariant' do
    it 'allows only one primary alias per user' do
      user = create(:user)
      create(:alias, user: user, email: 'a@example.com', primary_alias: true)
      another = build(:alias, user: user, email: 'b@example.com', primary_alias: true)
      expect(another).not_to be_valid
      expect(another.errors[:primary_alias]).to be_present
    end
  end
end

