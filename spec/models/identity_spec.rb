require 'rails_helper'

RSpec.describe Identity, type: :model do
  describe '.send_authorized' do
    let(:user) { create(:user) }

    it 'includes identities with refresh_token and no revoked_at' do
      ok = create(:identity, user: user, refresh_token: 'r')
      create(:identity, user: user, refresh_token: nil)
      create(:identity, user: user, refresh_token: 'r', send_revoked_at: Time.current)

      expect(Identity.send_authorized).to contain_exactly(ok)
    end
  end

  describe 'encryption' do
    it 'stores refresh_token encrypted at rest' do
      id = create(:identity, refresh_token: 'plain-secret')
      raw = ActiveRecord::Base.connection.execute(
        "SELECT refresh_token FROM identities WHERE id=#{id.id}"
      ).first['refresh_token']
      expect(raw).not_to include('plain-secret')
      expect(id.reload.refresh_token).to eq('plain-secret')
    end

    it 'stores access_token encrypted at rest' do
      id = create(:identity, access_token: 'access-secret')
      raw = ActiveRecord::Base.connection.execute(
        "SELECT access_token FROM identities WHERE id=#{id.id}"
      ).first['access_token']
      expect(raw).not_to include('access-secret')
      expect(id.reload.access_token).to eq('access-secret')
    end
  end

  describe '#send_authorized?' do
    it 'returns true when refresh_token present and not revoked' do
      expect(build(:identity, refresh_token: 'r', send_revoked_at: nil)).to be_send_authorized
    end

    it 'returns false when refresh_token blank' do
      expect(build(:identity, refresh_token: nil)).not_to be_send_authorized
    end

    it 'returns false when revoked' do
      expect(build(:identity, refresh_token: 'r', send_revoked_at: Time.current)).not_to be_send_authorized
    end

    it 'agrees with .send_authorized scope on empty-string refresh_token' do
      identity = create(:identity, refresh_token: 'r')
      Identity.where(id: identity.id).update_all(refresh_token: '')
      identity.reload
      scope_includes     = Identity.send_authorized.exists?(id: identity.id)
      predicate_says_yes = identity.send_authorized?
      expect(predicate_says_yes).to eq(scope_includes)
    end
  end
end
