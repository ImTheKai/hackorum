# Email Writing Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:executing-plans to implement this plan task-by-task.

**Goal:** Let users opt in to sending mailing-list replies via the Gmail API using a separate, narrowly-scoped OAuth grant; persist drafts; show pending messages until the IMAP echo arrives.

**Architecture:** Hybrid data model — `outgoing_drafts` table (private to author, no callbacks) + `state` column on `messages` (`pending`/`sent`). Send is a background job that calls the Gmail API; on success a `pending` `Message` is inserted and the draft destroyed. `EmailIngestor` is extended so the IMAP echo flips `pending` → `sent` via `Message-Id` match.

**Tech Stack:** Rails 8, Postgres, omniauth-google-oauth2, Rails 8 `encrypts`, solid_queue, Stimulus + Turbo, RSpec + FactoryBot + Capybara.

**Reference:** [docs/plans/2026-05-10-email-writing-design.md](2026-05-10-email-writing-design.md)

---

## Conventions used in this plan

- Every test step uses RSpec; run via `bundle exec rspec <path>`.
- Migrations use `rails generate migration` then `rails db:migrate RAILS_ENV=development RAILS_ENV=test`.
- Each task ends with one commit.
- "Verify" steps check schema/output rather than re-running already-passing tests.
- Conventional commit prefixes: `feat:`, `fix:`, `test:`, `refactor:`, `chore:`, `docs:`.

---

## Task 0: Pre-flight setup

**Files:**
- Modify: `.env.development.example`
- Modify: `config/credentials.yml.enc` (Rails 8 encryption keys, generated)

**Step 1: Add new env vars to `.env.development.example`**

Append:
```
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=
HACKORUM_DEV_REPLY_TO=
HACKORUM_OUTGOING_DOMAIN=hackorum.local
```

**Step 2: Initialize Rails 8 active_record encryption keys**

Run:
```bash
bin/rails db:encryption:init
```

Copy the output into `config/credentials.yml.enc` via `EDITOR=nano bin/rails credentials:edit`. Add:
```yaml
active_record_encryption:
  primary_key: <generated>
  deterministic_key: <generated>
  key_derivation_salt: <generated>
```

**Step 3: Verify encryption works**

```bash
bin/rails runner -e development 'puts ActiveRecord::Encryption.config.primary_key.to_s.length'
bin/rails runner -e development 'e = ActiveRecord::Encryption::Encryptor.new; puts e.decrypt(e.encrypt("hello"))'
```
Expected: first command prints a number ≥ 32; second prints `hello`. Errors mean keys not loaded.

**Note (deviation):** Original plan called for storing AR encryption keys in `config/credentials.yml.enc`. In environments without `RAILS_MASTER_KEY` (this dev container), keys are configured via ENV in `config/environments/development.rb` and `config/environments/test.rb` instead. Production deployment must set the same ENV vars (or migrate to credentials) — see §"Acceptance criteria" / Task 22.

**Step 4: Commit**

```bash
git add .env.development.example
# do NOT commit credentials.yml.enc changes here unless they were absent before
git commit -m "chore: add env vars for Gmail send + encryption keys"
```

---

## Task 1: Migration & model — extend `identities` with token storage

**Files:**
- Create: `db/migrate/<ts>_add_send_auth_to_identities.rb`
- Modify: `app/models/identity.rb`
- Modify: `spec/models/identity_spec.rb` (create if absent)
- Create: `spec/factories/identities.rb` (if absent)

**Step 1: Generate the migration**

```bash
bin/rails g migration AddSendAuthToIdentities \
  refresh_token:text access_token:text \
  access_token_expires_at:datetime \
  scopes:text send_authorized_at:datetime \
  send_revoked_at:datetime last_send_error:text
```

Edit the generated file — keep `text` types as-is (encryption stores ciphertext as text).

**Step 2: Run migration**

```bash
bin/rails db:migrate RAILS_ENV=development
bin/rails db:migrate RAILS_ENV=test
```

Verify:
```bash
bin/rails runner 'puts Identity.column_names.sort'
```
Expected to include `refresh_token`, `access_token`, etc.

**Step 3: Write Identity model spec for the new scope**

```ruby
# spec/models/identity_spec.rb
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
  end
end
```

If `spec/factories/identities.rb` doesn't exist:
```ruby
FactoryBot.define do
  factory :identity do
    user
    provider { 'google_oauth2' }
    sequence(:uid) { |n| "uid-#{n}" }
    sequence(:email) { |n| "id-#{n}@example.com" }
  end
end
```

**Step 4: Run, expect failure**

```bash
bundle exec rspec spec/models/identity_spec.rb
```
Expected: `NoMethodError: undefined method 'send_authorized'` or encryption assertion fails.

**Step 5: Implement on the model**

```ruby
# app/models/identity.rb
class Identity < ApplicationRecord
  belongs_to :user

  encrypts :refresh_token
  encrypts :access_token

  validates :provider, presence: true
  validates :uid, presence: true
  validates :uid, uniqueness: { scope: :provider }

  scope :send_authorized, -> {
    where.not(refresh_token: nil).where(send_revoked_at: nil)
  }

  def send_authorized?
    refresh_token.present? && send_revoked_at.nil?
  end
end
```

**Step 6: Run, expect pass**

```bash
bundle exec rspec spec/models/identity_spec.rb
```
Expected: `2 examples, 0 failures`.

**Step 7: Commit**

```bash
git add db/migrate/* app/models/identity.rb spec/models/identity_spec.rb spec/factories/identities.rb db/schema.rb
git commit -m "feat: store Gmail send tokens on Identity (encrypted)"
```

---

## Task 2: Migration & model — `state` and send-tracking columns on `messages`

**Files:**
- Create: `db/migrate/<ts>_add_state_to_messages.rb`
- Modify: `app/models/message.rb`
- Modify: `spec/models/message_spec.rb`

**Step 1: Generate migration**

```bash
bin/rails g migration AddStateToMessages \
  state:string sent_at:datetime sent_via_identity_id:bigint sent_to_address:string
```

Edit the migration:
```ruby
def up
  add_column :messages, :state, :string, default: "sent", null: false
  add_column :messages, :sent_at, :datetime
  add_column :messages, :sent_via_identity_id, :bigint
  add_column :messages, :sent_to_address, :string
  add_index :messages, :state
  add_foreign_key :messages, :identities, column: :sent_via_identity_id
end

def down
  remove_foreign_key :messages, column: :sent_via_identity_id
  remove_index :messages, :state
  remove_column :messages, :sent_to_address
  remove_column :messages, :sent_via_identity_id
  remove_column :messages, :sent_at
  remove_column :messages, :state
end
```

**Step 2: Run migration; verify default backfilled existing rows**

```bash
bin/rails db:migrate RAILS_ENV=development
bin/rails db:migrate RAILS_ENV=test
bin/rails runner 'puts Message.where(state: "sent").count, Message.count'
```
Both numbers must match in dev (all existing rows are echoed-from-IMAP).

**Step 3: Add state constants + scopes to Message; spec them**

```ruby
# spec/models/message_spec.rb (append)
describe 'state' do
  it 'defaults to sent' do
    expect(create(:message).state).to eq('sent')
  end

  it 'has helper predicates' do
    msg = build(:message, state: 'pending')
    expect(msg).to be_pending
    expect(msg).not_to be_sent
  end
end
```

```ruby
# app/models/message.rb (additions)
STATE_PENDING = "pending"
STATE_SENT    = "sent"

scope :pending, -> { where(state: STATE_PENDING) }
scope :sent,    -> { where(state: STATE_SENT) }

def pending? = state == STATE_PENDING
def sent?    = state == STATE_SENT
```

**Step 4: Run**

```bash
bundle exec rspec spec/models/message_spec.rb
```
Expected: pass.

**Step 5: Commit**

```bash
git add db/migrate/* app/models/message.rb spec/models/message_spec.rb db/schema.rb
git commit -m "feat: add pending/sent state to messages"
```

---

## Task 3: Migration — `mailing_lists.post_address`

**Files:**
- Create: `db/migrate/<ts>_add_post_address_to_mailing_lists.rb`

**Step 1: Generate + run**

```bash
bin/rails g migration AddPostAddressToMailingLists post_address:string
bin/rails db:migrate RAILS_ENV=development
bin/rails db:migrate RAILS_ENV=test
```

**Step 2: Verify**

```bash
bin/rails runner 'puts MailingList.column_names.include?("post_address")'
```
Expected: `true`.

**Step 3: Commit**

```bash
git add db/migrate/* db/schema.rb
git commit -m "feat: add post_address to mailing_lists"
```

---

## Task 4: Migration & model — `outgoing_drafts` table

**Files:**
- Create: `db/migrate/<ts>_create_outgoing_drafts.rb`
- Create: `app/models/outgoing_draft.rb`
- Create: `spec/models/outgoing_draft_spec.rb`
- Create: `spec/factories/outgoing_drafts.rb`

**Step 1: Migration**

```ruby
class CreateOutgoingDrafts < ActiveRecord::Migration[8.0]
  def change
    create_table :outgoing_drafts do |t|
      t.references :user,             null: false, foreign_key: true
      t.references :topic,            null: false, foreign_key: true
      t.references :reply_to_message, null: false, foreign_key: { to_table: :messages }
      t.references :sender_alias,     null: false, foreign_key: { to_table: :aliases }
      t.references :identity,         null: false, foreign_key: true
      t.string  :subject, null: false
      t.text    :body, null: false, default: ""
      t.string  :status, null: false, default: "idle"
      t.text    :last_send_error
      t.datetime :sending_started_at
      t.timestamps
    end
    add_index :outgoing_drafts, [:user_id, :reply_to_message_id], unique: true,
              name: "idx_drafts_user_parent_unique"
  end
end
```

**Step 2: Run migration**

```bash
bin/rails db:migrate RAILS_ENV=development
bin/rails db:migrate RAILS_ENV=test
```

**Step 3: Model + spec**

```ruby
# app/models/outgoing_draft.rb
class OutgoingDraft < ApplicationRecord
  STATUS_IDLE    = "idle"
  STATUS_SENDING = "sending"

  belongs_to :user
  belongs_to :topic
  belongs_to :reply_to_message, class_name: "Message"
  belongs_to :sender_alias, class_name: "Alias"
  belongs_to :identity

  validates :subject, presence: true
  validates :status, inclusion: { in: [STATUS_IDLE, STATUS_SENDING] }
  validates :user_id, uniqueness: { scope: :reply_to_message_id }

  scope :idle,    -> { where(status: STATUS_IDLE) }
  scope :sending, -> { where(status: STATUS_SENDING) }
  scope :stale_sending, ->(threshold = 10.minutes.ago) {
    sending.where("sending_started_at < ?", threshold)
  }

  def idle?    = status == STATUS_IDLE
  def sending? = status == STATUS_SENDING
end
```

```ruby
# spec/factories/outgoing_drafts.rb
FactoryBot.define do
  factory :outgoing_draft do
    user
    topic
    reply_to_message { create(:message, topic: topic) }
    sender_alias    { create(:alias, user: user) }
    identity        { create(:identity, user: user, refresh_token: 'r') }
    sequence(:subject) { |n| "Re: subject #{n}" }
    body { "" }
    status { "idle" }
  end
end
```

```ruby
# spec/models/outgoing_draft_spec.rb
require 'rails_helper'

RSpec.describe OutgoingDraft, type: :model do
  it 'is uniquely keyed by (user, reply_to_message)' do
    draft = create(:outgoing_draft)
    dup   = build(:outgoing_draft,
                  user: draft.user,
                  reply_to_message: draft.reply_to_message,
                  topic: draft.topic)
    expect(dup).not_to be_valid
  end

  it 'scopes idle and sending' do
    a = create(:outgoing_draft, status: 'idle')
    b = create(:outgoing_draft, status: 'sending', sending_started_at: 1.minute.ago)
    expect(OutgoingDraft.idle).to contain_exactly(a)
    expect(OutgoingDraft.sending).to contain_exactly(b)
  end

  it 'flags stale sending rows' do
    fresh = create(:outgoing_draft, status: 'sending', sending_started_at: 1.minute.ago)
    stale = create(:outgoing_draft, status: 'sending', sending_started_at: 1.hour.ago)
    expect(OutgoingDraft.stale_sending).to contain_exactly(stale)
  end
end
```

**Step 4: Run**

```bash
bundle exec rspec spec/models/outgoing_draft_spec.rb
```

**Step 5: Commit**

```bash
git add db/migrate/* app/models/outgoing_draft.rb spec/models/outgoing_draft_spec.rb spec/factories/outgoing_drafts.rb db/schema.rb
git commit -m "feat: add outgoing_drafts table and model"
```

---

## Task 5: `OAuth::TokenRefresher` service

**Files:**
- Create: `app/services/oauth/token_refresher.rb`
- Create: `spec/services/oauth/token_refresher_spec.rb`

**Step 1: Spec the four cases**

```ruby
# spec/services/oauth/token_refresher_spec.rb
require 'rails_helper'

RSpec.describe OAuth::TokenRefresher do
  let(:identity) {
    create(:identity, refresh_token: 'r1', access_token: nil,
           access_token_expires_at: nil)
  }

  it 'no-ops when access_token is fresh' do
    identity.update!(access_token: 'a', access_token_expires_at: 5.minutes.from_now)
    expect(Net::HTTP).not_to receive(:post_form)
    described_class.call(identity)
  end

  it 'refreshes when access_token is stale' do
    stub_post = instance_double(Net::HTTPSuccess, code: '200',
                                body: { access_token: 'newA', expires_in: 3600 }.to_json)
    allow(stub_post).to receive(:is_a?).and_return(true)
    expect(Net::HTTP).to receive(:post_form).and_return(stub_post)
    described_class.call(identity)
    expect(identity.reload.access_token).to eq('newA')
    expect(identity.access_token_expires_at).to be_within(2.seconds).of(1.hour.from_now)
  end

  it 'raises AuthRevokedError on 4xx and revokes locally' do
    stub_post = instance_double(Net::HTTPClientError, code: '400',
                                body: '{"error":"invalid_grant"}')
    allow(stub_post).to receive(:is_a?).and_return(false)
    expect(Net::HTTP).to receive(:post_form).and_return(stub_post)
    expect { described_class.call(identity) }.to raise_error(Gmail::AuthRevokedError)
    expect(identity.reload.send_revoked_at).not_to be_nil
    expect(identity.refresh_token).to be_nil
  end

  it 'raises TransientError on 5xx' do
    stub_post = instance_double(Net::HTTPServerError, code: '503', body: 'down')
    allow(stub_post).to receive(:is_a?).and_return(false)
    expect(Net::HTTP).to receive(:post_form).and_return(stub_post)
    expect { described_class.call(identity) }.to raise_error(Gmail::TransientError)
  end
end
```

**Step 2: Run, expect fail**

```bash
bundle exec rspec spec/services/oauth/token_refresher_spec.rb
```
Expected: `NameError: uninitialized constant OAuth::TokenRefresher`.

**Step 3: Implement**

```ruby
# app/services/oauth/token_refresher.rb
module OAuth
  class TokenRefresher
    TOKEN_URL = "https://oauth2.googleapis.com/token"

    def self.call(identity)
      return if identity.access_token.present? &&
                identity.access_token_expires_at &&
                identity.access_token_expires_at > 1.minute.from_now

      response = Net::HTTP.post_form(URI(TOKEN_URL), {
        client_id:     ENV.fetch("GOOGLE_CLIENT_ID"),
        client_secret: ENV.fetch("GOOGLE_CLIENT_SECRET"),
        refresh_token: identity.refresh_token,
        grant_type:    "refresh_token"
      })

      case response.code.to_i
      when 200
        body = JSON.parse(response.body)
        identity.update!(
          access_token:            body["access_token"],
          access_token_expires_at: body["expires_in"].to_i.seconds.from_now
        )
      when 400..499
        identity.update!(refresh_token: nil, access_token: nil,
                         access_token_expires_at: nil,
                         send_revoked_at: Time.current,
                         last_send_error: "Authorization revoked: #{response.body}")
        raise Gmail::AuthRevokedError, response.body
      else
        raise Gmail::TransientError, response.body
      end
    end
  end
end
```

Also create the error module (will be expanded in Task 7):
```ruby
# app/services/gmail.rb (or app/services/gmail/errors.rb)
module Gmail
  class TransientError < StandardError; end
  class PermanentError < StandardError; end
  class AuthRevokedError < PermanentError; end
end
```

**Step 4: Run, expect pass**

```bash
bundle exec rspec spec/services/oauth/token_refresher_spec.rb
```

**Step 5: Commit**

```bash
git add app/services/oauth/ app/services/gmail.rb spec/services/oauth/
git commit -m "feat: add OAuth::TokenRefresher with revocation handling"
```

---

## Task 6: `Gmail::SendClient`

**Files:**
- Create: `app/services/gmail/send_client.rb`
- Create: `spec/services/gmail/send_client_spec.rb`

**Step 1: Spec status mapping**

```ruby
# spec/services/gmail/send_client_spec.rb
require 'rails_helper'

RSpec.describe Gmail::SendClient do
  let(:identity) { create(:identity, access_token: 'tok') }
  let(:rfc822)   { "From: x@y\r\n\r\nbody" }

  def stub_response(code, body = "")
    res = double(code: code.to_s, body: body)
    allow(Net::HTTP).to receive(:start).and_yield(double(request: res))
    res
  end

  it 'returns parsed JSON on 200' do
    stub_response(200, '{"id":"abc"}')
    expect(described_class.send_raw(identity, rfc822)).to eq({"id" => "abc"})
  end

  it 'raises AuthRevokedError on 401' do
    stub_response(401, 'unauthorized')
    expect { described_class.send_raw(identity, rfc822) }.to raise_error(Gmail::AuthRevokedError)
  end

  it 'raises PermanentError on other 4xx' do
    stub_response(400, 'bad request')
    expect { described_class.send_raw(identity, rfc822) }.to raise_error(Gmail::PermanentError)
  end

  it 'raises TransientError on 5xx' do
    stub_response(503, 'down')
    expect { described_class.send_raw(identity, rfc822) }.to raise_error(Gmail::TransientError)
  end
end
```

**Step 2: Implement**

```ruby
# app/services/gmail/send_client.rb
require "net/http"
require "json"
require "base64"

module Gmail
  class SendClient
    URL = "https://gmail.googleapis.com/gmail/v1/users/me/messages/send"

    def self.send_raw(identity, rfc822_string)
      uri  = URI(URL)
      raw  = Base64.urlsafe_encode64(rfc822_string)
      body = { raw: raw }.to_json

      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "Bearer #{identity.access_token}"
      req["Content-Type"]  = "application/json"
      req.body = body

      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }

      case res.code.to_i
      when 200      then JSON.parse(res.body)
      when 401, 403 then raise AuthRevokedError, res.body
      when 400..499 then raise PermanentError,   res.body
      else               raise TransientError,   res.body
      end
    end
  end
end
```

**Step 3: Run**

```bash
bundle exec rspec spec/services/gmail/send_client_spec.rb
```

**Step 4: Commit**

```bash
git add app/services/gmail/send_client.rb spec/services/gmail/
git commit -m "feat: add Gmail::SendClient"
```

---

## Task 7: `RecipientResolver`

**Files:**
- Create: `app/services/outgoing/recipient_resolver.rb`
- Create: `spec/services/outgoing/recipient_resolver_spec.rb`

**Step 1: Spec all branches**

```ruby
require 'rails_helper'

RSpec.describe Outgoing::RecipientResolver do
  let(:list) { create(:mailing_list, post_address: "real@list.example") }
  let(:topic) { create(:topic, mailing_lists: [list]) }

  context 'in production' do
    before { allow(Rails.env).to receive(:production?).and_return(true) }

    it 'returns post_address' do
      expect(described_class.for(topic)).to eq("real@list.example")
    end

    it 'raises when blank' do
      list.update!(post_address: nil)
      expect { described_class.for(topic) }
        .to raise_error(Outgoing::RecipientResolver::MissingPostAddressError)
    end
  end

  context 'in development' do
    it 'returns the override' do
      ClimateControl.modify HACKORUM_DEV_REPLY_TO: "test@example.com" do
        expect(described_class.for(topic)).to eq("test@example.com")
      end
    end

    it 'raises when override missing' do
      ClimateControl.modify HACKORUM_DEV_REPLY_TO: nil do
        expect { described_class.for(topic) }
          .to raise_error(Outgoing::RecipientResolver::MissingDevOverrideError)
      end
    end

    it 'raises when override matches a real list address' do
      ClimateControl.modify HACKORUM_DEV_REPLY_TO: "REAL@list.example" do
        expect { described_class.for(topic) }
          .to raise_error(Outgoing::RecipientResolver::RealListAddressInDevError)
      end
    end
  end
end
```

Add `gem "climate_control", group: :test` to Gemfile if absent. Run `bundle install`.

**Step 2: Implement**

```ruby
# app/services/outgoing/recipient_resolver.rb
module Outgoing
  class RecipientResolver
    class MissingPostAddressError   < StandardError; end
    class MissingDevOverrideError   < StandardError; end
    class RealListAddressInDevError < StandardError; end

    def self.for(topic)
      list = topic.mailing_lists.first
      raise MissingPostAddressError if list.nil? || list.post_address.blank?

      if Rails.env.production?
        list.post_address
      else
        override = ENV["HACKORUM_DEV_REPLY_TO"]
        raise MissingDevOverrideError if override.blank?
        if MailingList.where("lower(post_address) = lower(?)", override).exists?
          raise RealListAddressInDevError
        end
        override
      end
    end
  end
end
```

**Step 3: Run + commit**

```bash
bundle exec rspec spec/services/outgoing/recipient_resolver_spec.rb
git add app/services/outgoing/ spec/services/outgoing/ Gemfile Gemfile.lock
git commit -m "feat: add Outgoing::RecipientResolver"
```

---

## Task 8: `OutgoingMessageBuilder`

**Files:**
- Create: `app/services/outgoing/message_builder.rb`
- Create: `spec/services/outgoing/message_builder_spec.rb`

**Step 1: Spec**

```ruby
require 'rails_helper'

RSpec.describe Outgoing::MessageBuilder do
  let(:list)       { create(:mailing_list, post_address: "list@example.com") }
  let(:parent)     { create(:message, message_id: "<parent-id@x>",
                            mailing_lists: [list]) }
  let(:user)       { create(:user) }
  let(:identity)   { create(:identity, user: user, email: 'a@b',
                            refresh_token: 'r') }
  let(:sender)     { create(:alias, user: user, name: 'Alice', email: 'a@b') }
  let(:draft) {
    create(:outgoing_draft,
           user: user, topic: parent.topic, reply_to_message: parent,
           sender_alias: sender, identity: identity,
           subject: 'Re: hello', body: 'hi')
  }

  before do
    ClimateControl.modify(
      HACKORUM_DEV_REPLY_TO: "test@example.com",
      HACKORUM_OUTGOING_DOMAIN: "hackorum.local"
    ) { example.run } if example.metadata[:climate_modify]
  end

  it 'builds RFC822 with proper threading headers', climate_modify: true do
    result = described_class.build(draft)
    mail = Mail.new(result.encoded)

    expect(mail.from).to eq(['a@b'])
    expect(mail.to).to eq(['test@example.com'])
    expect(mail.subject).to eq('Re: hello')
    expect(mail.in_reply_to).to eq('parent-id@x')
    expect(mail.references).to include('parent-id@x')
    expect(mail.body.to_s).to eq('hi')
    expect(result.message_id).to start_with('<')
    expect(result.message_id).to end_with('@hackorum.local>')
  end

  it 'walks the parent chain for References', climate_modify: true do
    grand = create(:message, message_id: '<grand@x>')
    parent.update!(reply_to: grand, reply_to_message_id: '<grand@x>')
    result = described_class.build(draft)
    mail = Mail.new(result.encoded)
    refs = mail.references
    refs = [refs] unless refs.is_a?(Array)
    expect(refs).to include('grand@x', 'parent-id@x')
  end
end
```

**Step 2: Implement**

```ruby
# app/services/outgoing/message_builder.rb
module Outgoing
  class MessageBuilder
    Result = Struct.new(:encoded, :message_id, :subject, :recipient, keyword_init: true)

    def self.build(draft)
      recipient = RecipientResolver.for(draft.topic)
      msg_id    = "<#{SecureRandom.uuid}@#{ENV.fetch('HACKORUM_OUTGOING_DOMAIN', 'hackorum.local')}>"

      mail = Mail.new do
        from       "#{draft.sender_alias.name} <#{draft.sender_alias.email}>"
        to         recipient
        subject    draft.subject
        message_id msg_id
        body       draft.body
      end
      mail.content_type 'text/plain; charset=UTF-8'
      mail.in_reply_to = draft.reply_to_message.message_id
      mail.references  = build_references(draft.reply_to_message)

      Result.new(encoded: mail.encoded, message_id: msg_id,
                 subject: draft.subject, recipient: recipient)
    end

    def self.build_references(parent)
      chain = []
      cur = parent
      while cur
        chain.unshift(cur.message_id) if cur.message_id.present?
        cur = cur.reply_to
      end
      chain.uniq
    end
  end
end
```

**Step 3: Run + commit**

```bash
bundle exec rspec spec/services/outgoing/message_builder_spec.rb
git add app/services/outgoing/message_builder.rb spec/services/outgoing/message_builder_spec.rb
git commit -m "feat: add Outgoing::MessageBuilder for RFC822 construction"
```

---

## Task 9: `SendOutgoingMessageJob`

**Files:**
- Create: `app/jobs/send_outgoing_message_job.rb`
- Create: `spec/jobs/send_outgoing_message_job_spec.rb`

**Step 1: Spec the four primary paths**

```ruby
require 'rails_helper'

RSpec.describe SendOutgoingMessageJob do
  let(:draft) { create(:outgoing_draft, status: 'sending',
                       sending_started_at: 1.second.ago) }

  before do
    allow(OAuth::TokenRefresher).to receive(:call)
    builder_result = Outgoing::MessageBuilder::Result.new(
      encoded: "raw", message_id: "<m@x>", subject: "s", recipient: "to@x")
    allow(Outgoing::MessageBuilder).to receive(:build).and_return(builder_result)
  end

  it 'creates a pending message and destroys the draft on success' do
    allow(Gmail::SendClient).to receive(:send_raw).and_return({"id" => "g"})
    expect {
      described_class.new.perform(draft.id)
    }.to change(Message, :count).by(1).and change(OutgoingDraft, :count).by(-1)
    msg = Message.last
    expect(msg.state).to eq('pending')
    expect(msg.message_id).to eq('<m@x>')
    expect(msg.sent_to_address).to eq('to@x')
    expect(msg.sent_via_identity_id).to eq(draft.identity_id)
  end

  it 'flips draft to idle with error on PermanentError' do
    allow(Gmail::SendClient).to receive(:send_raw).and_raise(Gmail::PermanentError, 'bad')
    described_class.new.perform(draft.id)
    draft.reload
    expect(draft).to be_idle
    expect(draft.last_send_error).to include('bad')
  end

  it 'revokes identity on AuthRevokedError' do
    allow(Gmail::SendClient).to receive(:send_raw).and_raise(Gmail::AuthRevokedError, 'no')
    described_class.new.perform(draft.id)
    expect(draft.identity.reload.send_revoked_at).not_to be_nil
    expect(draft.reload).to be_idle
  end

  it 'lets TransientError propagate for ActiveJob retry' do
    allow(Gmail::SendClient).to receive(:send_raw).and_raise(Gmail::TransientError, 'srv')
    expect { described_class.new.perform(draft.id) }
      .to raise_error(Gmail::TransientError)
  end
end
```

**Step 2: Implement**

```ruby
# app/jobs/send_outgoing_message_job.rb
class SendOutgoingMessageJob < ApplicationJob
  queue_as :default

  retry_on Gmail::TransientError, wait: :polynomially_longer, attempts: 5

  def perform(draft_id)
    draft = OutgoingDraft.find_by(id: draft_id)
    return unless draft && draft.sending?

    OAuth::TokenRefresher.call(draft.identity)
    rfc = Outgoing::MessageBuilder.build(draft)
    Gmail::SendClient.send_raw(draft.identity, rfc.encoded)

    Message.transaction do
      msg = Message.create!(
        topic:                draft.topic,
        sender:               draft.sender_alias,
        sender_person_id:     draft.sender_alias.person_id,
        reply_to:             draft.reply_to_message,
        reply_to_message_id:  draft.reply_to_message.message_id,
        subject:              rfc.subject,
        body:                 draft.body,
        message_id:           rfc.message_id,
        state:                Message::STATE_PENDING,
        sent_at:              Time.current,
        sent_via_identity_id: draft.identity_id,
        sent_to_address:      rfc.recipient
      )
      draft.destroy!
      Turbo::StreamsChannel.broadcast_append_to(draft.topic, target: "messages",
        partial: "topics/message", locals: { message: msg })
    end
  rescue Gmail::AuthRevokedError => e
    fail_draft(draft, "Authorization revoked: #{e.message}")
    draft.identity.update!(send_revoked_at: Time.current,
                           refresh_token: nil, access_token: nil)
  rescue Gmail::PermanentError => e
    fail_draft(draft, e.message)
  end

  private

  def fail_draft(draft, msg)
    draft.update!(status: OutgoingDraft::STATUS_IDLE,
                  last_send_error: msg, sending_started_at: nil)
  end
end
```

**Step 3: Run + commit**

```bash
bundle exec rspec spec/jobs/send_outgoing_message_job_spec.rb
git add app/jobs/send_outgoing_message_job.rb spec/jobs/
git commit -m "feat: add SendOutgoingMessageJob"
```

---

## Task 10: Stale-sending sweep job

**Files:**
- Create: `app/jobs/reset_stale_sending_drafts_job.rb`
- Create: `spec/jobs/reset_stale_sending_drafts_job_spec.rb`
- Modify: `config/recurring.yml` (or solid_queue equivalent)

**Step 1: Spec**

```ruby
require 'rails_helper'

RSpec.describe ResetStaleSendingDraftsJob do
  it 'resets drafts stuck in sending older than 10 minutes' do
    fresh = create(:outgoing_draft, status: 'sending', sending_started_at: 1.minute.ago)
    stale = create(:outgoing_draft, status: 'sending', sending_started_at: 1.hour.ago)
    described_class.new.perform
    expect(fresh.reload).to be_sending
    expect(stale.reload).to be_idle
    expect(stale.last_send_error).to include('stuck')
  end
end
```

**Step 2: Implement**

```ruby
class ResetStaleSendingDraftsJob < ApplicationJob
  queue_as :default
  def perform
    OutgoingDraft.stale_sending.find_each do |d|
      d.update!(status: OutgoingDraft::STATUS_IDLE,
                last_send_error: "Send was stuck — please try again",
                sending_started_at: nil)
    end
  end
end
```

**Step 3: Schedule (solid_queue recurring)**

`config/recurring.yml`:
```yaml
production:
  reset_stale_drafts:
    class: ResetStaleSendingDraftsJob
    schedule: every 5 minutes
development:
  reset_stale_drafts:
    class: ResetStaleSendingDraftsJob
    schedule: every 5 minutes
```

If `config/recurring.yml` exists, append; otherwise create.

**Step 4: Run + commit**

```bash
bundle exec rspec spec/jobs/reset_stale_sending_drafts_job_spec.rb
git add app/jobs/reset_stale_sending_drafts_job.rb spec/jobs/reset_stale_sending_drafts_job_spec.rb config/recurring.yml
git commit -m "feat: sweep stale 'sending' drafts every 5 minutes"
```

---

## Task 11: Echo handling — extend `EmailIngestor`

**Files:**
- Modify: `app/services/email_ingestor.rb` (lines around `update_existing_message`)
- Modify: `spec/services/email_ingestor_spec.rb`

**Step 1: Spec**

```ruby
# append to spec/services/email_ingestor_spec.rb
describe 'pending message echo' do
  let(:list) { create(:mailing_list) }
  let(:user) { create(:user) }
  let(:sender) { create(:alias, user: user, email: 'a@b', name: 'Alice') }
  let!(:topic) { create(:topic, creator: sender) }
  let!(:pending) {
    Message.create!(topic: topic, sender: sender, sender_person_id: sender.person_id,
                    subject: 'Re: hi', body: 'body',
                    message_id: '<echo-test@x>',
                    state: 'pending', sent_at: 1.minute.ago)
  }

  it 'flips a pending message to sent when echo arrives' do
    raw = <<~EML
      From: Alice <a@b>
      To: list@example.com
      Subject: Re: hi
      Message-Id: <echo-test@x>
      Date: #{Time.current.rfc822}

      body
    EML
    described_class.new.ingest_raw(raw, mailing_list: list)
    expect(pending.reload.state).to eq('sent')
    expect(pending.message_mailing_lists.where(mailing_list: list)).to exist
  end

  it 'does not double-count topic counters on echo' do
    raw = "Message-Id: <echo-test@x>\nFrom: a@b\nTo: list@x\nSubject: Re: hi\nDate: #{Time.current.rfc822}\n\nbody"
    expect { described_class.new.ingest_raw(raw, mailing_list: list) }
      .not_to change { topic.reload.message_count }
  end
end
```

**Step 2: Implement**

In `app/services/email_ingestor.rb`, locate `update_existing_message` (~ line 86):

```ruby
def update_existing_message(message, body:, sent_at:, reply_to_message_id:, update_existing:)
  updates = {}
  updates[:body] = body if update_existing.include?(:body)
  updates[:created_at] = sent_at if update_existing.include?(:sent_at) && sent_at
  if update_existing.include?(:reply_to_message_id) && reply_to_message_id
    updates[:reply_to_message_id] = reply_to_message_id
  end

  # NEW: pending echo flips to sent. Counters already fired at insert.
  if message.state == Message::STATE_PENDING
    updates[:state] = Message::STATE_SENT
  end

  message.update_columns(updates) if updates.any?
end
```

**Step 3: Run + commit**

```bash
bundle exec rspec spec/services/email_ingestor_spec.rb
git add app/services/email_ingestor.rb spec/services/email_ingestor_spec.rb
git commit -m "feat: flip pending message to sent on IMAP echo"
```

---

## Task 12: Switch omniauth to dynamic per-request scope

**Files:**
- Modify: `config/initializers/omniauth.rb`
- Create: `spec/requests/omniauth_send_scope_spec.rb`

**Step 1: Spec**

```ruby
# spec/requests/omniauth_send_scope_spec.rb
require 'rails_helper'

RSpec.describe 'OmniAuth scope selection', type: :request do
  it 'uses gmail.send scope and offline access when send=1' do
    OmniAuth.config.test_mode = true
    # Capture the request-phase setup
    captured = nil
    OmniAuth.config.before_request_phase = ->(env) { captured = env.dup }

    get '/auth/google_oauth2?send=1'
    # In test mode, we just verify the env had the right scope set by setup proc
    options = captured["omniauth.strategy"]&.options
    expect(options[:scope]).to include('gmail.send') if options
    expect(options[:access_type]).to eq('offline') if options
    OmniAuth.config.before_request_phase = nil
  end
end
```

(Test approach varies; if request phase introspection is awkward, replace with a unit test of the setup lambda extracted into a class method.)

**Step 2: Implement**

```ruby
# config/initializers/omniauth.rb
DEFAULT_SCOPE = "email,profile".freeze
SEND_SCOPE    = "email profile https://www.googleapis.com/auth/gmail.send".freeze

SETUP_PROC = ->(env) {
  request = Rack::Request.new(env)
  if request.params["send"] == "1"
    env["omniauth.strategy"].options[:scope]       = SEND_SCOPE
    env["omniauth.strategy"].options[:access_type] = "offline"
    env["omniauth.strategy"].options[:prompt]      = "consent"
  else
    env["omniauth.strategy"].options[:scope]       = DEFAULT_SCOPE
    env["omniauth.strategy"].options[:access_type] = "online"
    env["omniauth.strategy"].options[:prompt]      = "select_account"
  end
}

Rails.application.config.middleware.use OmniAuth::Builder do
  provider :google_oauth2,
           ENV["GOOGLE_CLIENT_ID"],
           ENV["GOOGLE_CLIENT_SECRET"],
           setup: SETUP_PROC
end

OmniAuth.config.allowed_request_methods = [ :post, :get ]
OmniAuth.config.silence_get_warning = true
```

**Step 3: Run + commit**

```bash
bundle exec rspec spec/requests/omniauth_send_scope_spec.rb
git add config/initializers/omniauth.rb spec/requests/omniauth_send_scope_spec.rb
git commit -m "feat: dynamic OAuth scope for gmail.send authorization"
```

---

## Task 13: Callback — handle `send=1` branch

**Files:**
- Modify: `app/controllers/omniauth_callbacks_controller.rb`
- Modify: `spec/requests/` (add a request spec or extend an existing one)

**Step 1: Spec**

```ruby
# spec/requests/omniauth_send_authorization_spec.rb
require 'rails_helper'

RSpec.describe 'Send authorization callback', type: :request do
  before { OmniAuth.config.test_mode = true }
  after  { OmniAuth.config.test_mode = false }

  let(:user) { create(:user) }

  before do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: 'google_oauth2',
      uid: 'g-uid-1',
      info: { email: 'alice@gmail.com', name: 'Alice' },
      credentials: { token: 'a-tok', refresh_token: 'r-tok', expires_at: 1.hour.from_now.to_i }
    )
    sign_in_as(user)
  end

  it 'stores tokens on identity and auto-verifies alias' do
    get '/auth/google_oauth2/callback?send=1'
    follow_redirect!
    identity = user.reload.identities.find_by(uid: 'g-uid-1')
    expect(identity.refresh_token).to eq('r-tok')
    expect(identity.access_token).to eq('a-tok')
    expect(identity.send_authorized_at).not_to be_nil
    expect(identity.scopes).to include('gmail.send')
    expect(user.reload.aliases.where(email: 'alice@gmail.com').first.verified_at).not_to be_nil
  end
end
```

(`sign_in_as` helper: add in `spec/support/auth_helpers.rb` if absent — sets `session[:user_id]`.)

**Step 2: Implement**

In `app/controllers/omniauth_callbacks_controller.rb`, augment the existing `linking` branch with a parallel `sending` branch:

```ruby
sending = omniauth_params["send"].present?

if sending
  return redirect_to new_session_path, alert: "Sign in first." unless current_user

  # alias auto-verify (reuse the existing helper logic)
  alias_record = ensure_verified_alias(current_user, email, info)

  identity = Identity.find_or_initialize_by(provider: provider, uid: uid)
  if identity.persisted? && identity.user_id != current_user.id
    return redirect_to settings_account_path,
                       alert: "That Google account is linked to another user."
  end
  identity.assign_attributes(
    user: current_user, email: email, raw_info: auth.to_json,
    access_token: auth.dig("credentials", "token"),
    refresh_token: auth.dig("credentials", "refresh_token"),
    access_token_expires_at: Time.at(auth.dig("credentials", "expires_at").to_i),
    scopes: SEND_SCOPE,
    send_authorized_at: Time.current,
    send_revoked_at: nil,
    last_send_error: nil,
    last_used_at: Time.current
  )
  identity.save!
  return redirect_to settings_account_path, notice: "Sending authorized."
end
```

Extract `ensure_verified_alias(user, email, info)` from the existing linking-flow logic (DRY: refactor first, then reuse).

**Step 3: Run + commit**

```bash
bundle exec rspec spec/requests/omniauth_send_authorization_spec.rb
git add app/controllers/omniauth_callbacks_controller.rb spec/requests/omniauth_send_authorization_spec.rb spec/support/auth_helpers.rb
git commit -m "feat: handle ?send=1 in OAuth callback (auto-verify + tokens)"
```

---

## Task 14: Settings UI — Email sending section + revoke

**Files:**
- Create: `app/controllers/settings/send_auth_controller.rb`
- Modify: `config/routes.rb` (add `resource :send_auth` under `namespace :settings`)
- Modify: `app/views/settings/accounts/show.html.slim`
- Create: `spec/requests/settings/send_auth_spec.rb`
- Modify: `app/models/user.rb` (add `can_send_email?`)

**Step 1: Add User helper**

```ruby
# app/models/user.rb
def can_send_email?
  identities.send_authorized.exists?
end
```

**Step 2: Routes + controller**

```ruby
# config/routes.rb (inside namespace :settings)
resource :send_auth, only: [:destroy]
```

```ruby
# app/controllers/settings/send_auth_controller.rb
module Settings
  class SendAuthController < ApplicationController
    before_action :require_authentication

    def destroy
      identity = current_user.identities.send_authorized.find(params[:identity_id])
      revoke_remotely(identity)  # best-effort
      identity.update!(refresh_token: nil, access_token: nil,
                       access_token_expires_at: nil,
                       send_revoked_at: Time.current)
      redirect_to settings_account_path, notice: "Sending authorization revoked."
    end

    private

    def revoke_remotely(identity)
      Net::HTTP.post_form(URI("https://oauth2.googleapis.com/revoke"),
                          token: identity.refresh_token)
    rescue StandardError => e
      Rails.logger.warn("Google revoke failed: #{e.message}")
    end
  end
end
```

Adjust route to take `identity_id`:
```ruby
delete "send_auth/:identity_id", to: "send_auth#destroy", as: :send_auth
```

**Step 3: View — add section to settings/accounts/show.html.slim**

```slim
.settings-section
  h2 Email sending
  - send_id = @identities.find { |i| i.refresh_token.present? && i.send_revoked_at.nil? }
  - if send_id
    p Status: Authorized as #{send_id.email}
    p Authorized: #{l(send_id.send_authorized_at, format: :short) if send_id.send_authorized_at}
    - if send_id.last_send_error.present?
      .error-banner Last error: #{send_id.last_send_error}
    = button_to "Revoke authorization", settings_send_auth_path(identity_id: send_id.id),
                method: :delete, data: { turbo_confirm: "Revoke sending?" },
                class: "button-danger"
  - else
    p Authorize Hackorum to send replies via your Google account. Uses the gmail.send scope (send-only).
    = link_to "Authorize sending", "/auth/google_oauth2?send=1",
              class: "button-primary", data: { turbo: false }
```

**Step 4: Request spec**

```ruby
# spec/requests/settings/send_auth_spec.rb
require 'rails_helper'

RSpec.describe 'Settings::SendAuth', type: :request do
  let(:user) { create(:user) }
  let!(:identity) { create(:identity, user: user, refresh_token: 'r', access_token: 'a') }

  before { sign_in_as(user) }

  it 'revokes locally even if google revoke fails' do
    allow(Net::HTTP).to receive(:post_form).and_raise(SocketError, 'down')
    delete "/settings/send_auth/#{identity.id}"
    expect(identity.reload.refresh_token).to be_nil
    expect(identity.send_revoked_at).not_to be_nil
  end
end
```

**Step 5: Run + commit**

```bash
bundle exec rspec spec/requests/settings/send_auth_spec.rb
git add app/controllers/settings/send_auth_controller.rb app/views/settings/accounts/show.html.slim app/models/user.rb config/routes.rb spec/requests/settings/send_auth_spec.rb
git commit -m "feat: settings page section + revoke for Gmail send authorization"
```

---

## Task 15: `DraftsController` — CRUD

**Files:**
- Create: `app/controllers/drafts_controller.rb`
- Modify: `config/routes.rb`
- Create: `spec/requests/drafts_controller_spec.rb`

**Step 1: Routes**

```ruby
resources :drafts, controller: "drafts", only: [:create, :update, :destroy] do
  member do
    get  :confirm
    post :send_now
  end
end
```

**Step 2: Spec the four endpoints**

```ruby
# spec/requests/drafts_controller_spec.rb
require 'rails_helper'

RSpec.describe 'Drafts', type: :request do
  let(:user)     { create(:user) }
  let(:identity) { create(:identity, user: user, refresh_token: 'r') }
  let(:list)     { create(:mailing_list, post_address: 'real@list.example') }
  let(:topic)    { create(:topic, mailing_lists: [list]) }
  let(:parent)   { create(:message, topic: topic) }
  let(:sender)   { create(:alias, user: user, email: identity.email) }

  before { sign_in_as(user) }

  describe 'POST /drafts' do
    it 'creates or returns existing draft for parent' do
      post '/drafts', params: { reply_to_message_id: parent.id }
      first_id = JSON.parse(response.body)['id']
      post '/drafts', params: { reply_to_message_id: parent.id }
      second_id = JSON.parse(response.body)['id']
      expect(first_id).to eq(second_id)
    end
  end

  describe 'PATCH /drafts/:id' do
    let(:draft) { create(:outgoing_draft, user: user) }
    it 'updates body and subject' do
      patch "/drafts/#{draft.id}", params: { outgoing_draft: { body: 'new', subject: 'Re: x' } }
      expect(response).to have_http_status(:no_content)
      expect(draft.reload.body).to eq('new')
    end
    it 'returns 409 when status=sending' do
      draft.update!(status: 'sending', sending_started_at: 1.second.ago)
      patch "/drafts/#{draft.id}", params: { outgoing_draft: { body: 'new' } }
      expect(response).to have_http_status(:conflict)
    end
    it 'forbids editing another user’s draft' do
      other_draft = create(:outgoing_draft)
      patch "/drafts/#{other_draft.id}", params: { outgoing_draft: { body: 'x' } }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'DELETE /drafts/:id' do
    let(:draft) { create(:outgoing_draft, user: user) }
    it 'destroys the draft' do
      expect { delete "/drafts/#{draft.id}" }
        .to change(OutgoingDraft, :count).by(-1)
    end
  end
end
```

**Step 3: Implement**

```ruby
# app/controllers/drafts_controller.rb
class DraftsController < ApplicationController
  before_action :require_authentication
  before_action :set_draft, only: [:update, :destroy, :confirm, :send_now]

  def create
    parent = Message.find(params[:reply_to_message_id])
    identity = current_user.identities.send_authorized.first ||
               (return head(:forbidden))
    sender = current_user.aliases.find_by(email: identity.email) ||
             (return head(:unprocessable_entity))

    draft = OutgoingDraft.find_or_create_by!(
      user: current_user, reply_to_message: parent
    ) do |d|
      d.topic        = parent.topic
      d.identity     = identity
      d.sender_alias = sender
      d.subject      = "Re: " + parent.subject.to_s.sub(/\A(re|aw|fwd):\s*/i, "")
    end
    render json: { id: draft.id }
  end

  def update
    return head :conflict if @draft.sending?
    @draft.update!(params.require(:outgoing_draft).permit(:body, :subject))
    head :no_content
  end

  def destroy
    @draft.destroy!
    head :no_content
  end

  def confirm
    @recipient = Outgoing::RecipientResolver.for(@draft.topic)
    render layout: false   # turbo frame
  rescue Outgoing::RecipientResolver::RealListAddressInDevError,
         Outgoing::RecipientResolver::MissingDevOverrideError,
         Outgoing::RecipientResolver::MissingPostAddressError => e
    render plain: e.message, status: :unprocessable_entity
  end

  def send_now
    @draft.with_lock do
      return head :conflict unless @draft.idle?
      @draft.update!(status: OutgoingDraft::STATUS_SENDING,
                     sending_started_at: Time.current,
                     last_send_error: nil)
    end
    SendOutgoingMessageJob.perform_later(@draft.id)
    redirect_to topic_path(@draft.topic, anchor: "message-#{@draft.reply_to_message_id}")
  end

  private

  def set_draft
    @draft = current_user.outgoing_drafts.find(params[:id])
  end
end
```

**Step 4: Run + commit**

```bash
bundle exec rspec spec/requests/drafts_controller_spec.rb
git add app/controllers/drafts_controller.rb config/routes.rb spec/requests/drafts_controller_spec.rb
git commit -m "feat: drafts controller (CRUD + send_now + confirm)"
```

---

## Task 16: Reply button + composer partial

**Files:**
- Modify: `app/views/topics/_message.html.slim`
- Create: `app/views/drafts/_composer.html.slim`
- Create: `app/views/drafts/create.turbo_stream.slim`

**Step 1: Add reply button to `_message.html.slim`**

After the `.message-archive-link` block (line ~54), inside `.message-meta`:

```slim
- if user_signed_in? && current_user.can_send_email?
  - draft = @drafts_by_parent && @drafts_by_parent[message.id]
  - if draft
    = turbo_frame_tag "draft-#{message.id}", src: edit_draft_path(draft)
  - else
    = button_to "Reply", drafts_path, params: { reply_to_message_id: message.id },
                method: :post, class: "message-reply-button",
                form: { data: { turbo_frame: "draft-#{message.id}" } }
  = turbo_frame_tag "draft-#{message.id}"
```

**Step 2: Create composer partial**

```slim
/ app/views/drafts/_composer.html.slim
= turbo_frame_tag "draft-#{draft.reply_to_message_id}"
  .composer-card data-controller="reply-composer" data-reply-composer-draft-id-value=draft.id
    .composer-meta
      span.composer-from Sending as: #{draft.sender_alias.name} <#{draft.sender_alias.email}>
      span.composer-status data-reply-composer-target="status"
    = form_with model: draft, url: draft_path(draft), method: :patch, local: false, html: { data: { reply_composer_target: "form", action: "input->reply-composer#dirty blur->reply-composer#save" } } do |f|
      .composer-field
        = f.label :subject
        = f.text_field :subject
      .composer-field
        = f.text_area :body, data: { reply_composer_target: "body" }
    - if draft.last_send_error.present?
      .error-banner = draft.last_send_error
    .composer-actions
      = button_tag "Send", type: "button", class: "button-primary",
                   data: { action: "click->reply-composer#openConfirm" }
      = button_to "Discard", draft_path(draft), method: :delete,
                  data: { turbo_confirm: draft.body.present? ? "Discard draft?" : nil }
```

```slim
/ app/views/drafts/create.turbo_stream.slim
= turbo_stream.replace "draft-#{@draft.reply_to_message_id}", partial: "drafts/composer", locals: { draft: @draft }
```

Update `DraftsController#create` to support turbo_stream format:
```ruby
def create
  ...
  respond_to do |format|
    format.turbo_stream { @draft = draft; render :create }
    format.json { render json: { id: draft.id } }
  end
end
```

**Step 3: Add an `edit_draft` route + action**

```ruby
resources :drafts, ... do
  member { get :edit; ... }
end
```
```ruby
def edit
  render partial: "drafts/composer", locals: { draft: @draft }, layout: false
end
```

**Step 4: Preload drafts in `TopicsController#show`**

```ruby
@drafts_by_parent = if user_signed_in?
  current_user.outgoing_drafts.where(topic_id: @topic.id).index_by(&:reply_to_message_id)
else
  {}
end
```

**Step 5: Verify (no automated test for view yet — covered by Task 19 system test)**

```bash
make dev   # smoke check: open a topic, click Reply
```

**Step 6: Commit**

```bash
git add app/views/topics/_message.html.slim app/views/drafts/ app/controllers/drafts_controller.rb app/controllers/topics_controller.rb config/routes.rb
git commit -m "feat: per-message reply button + inline composer Turbo Frame"
```

---

## Task 17: Stimulus `reply-composer` controller (autosave)

**Files:**
- Create: `app/javascript/controllers/reply_composer_controller.js`
- Modify: `app/javascript/controllers/index.js` (autoregistered if using stimulus-loading; verify)

**Step 1: Implement**

```javascript
// app/javascript/controllers/reply_composer_controller.js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values  = { draftId: Number }
  static targets = ["form", "status", "body"]

  connect() {
    this.dirtyTimer = null
  }

  dirty() {
    if (this.statusTarget) this.statusTarget.textContent = "Editing…"
    clearTimeout(this.dirtyTimer)
    this.dirtyTimer = setTimeout(() => this.save(), 2000)
  }

  async save() {
    clearTimeout(this.dirtyTimer)
    if (this.statusTarget) this.statusTarget.textContent = "Saving…"
    const formData = new FormData(this.formTarget)
    const res = await fetch(this.formTarget.action, {
      method: "PATCH",
      body: formData,
      headers: { "X-CSRF-Token": document.querySelector('meta[name=csrf-token]').content,
                 "Accept": "text/vnd.turbo-stream.html, application/json" }
    })
    if (res.status === 204)      { this.statusTarget.textContent = "Saved" }
    else if (res.status === 409) { this.statusTarget.textContent = "Sending… (read-only)" }
    else                          { this.statusTarget.textContent = "Save failed" }
  }

  openConfirm(event) {
    event.preventDefault()
    Turbo.visit(`/drafts/${this.draftIdValue}/confirm`, { frame: `confirm-${this.draftIdValue}` })
  }
}
```

**Step 2: Manual verify**

Open dev, open a topic, type into composer → status shows "Editing…", then "Saving…" → "Saved" after 2s.

**Step 3: Commit**

```bash
git add app/javascript/controllers/reply_composer_controller.js
git commit -m "feat: autosave Stimulus controller for reply composer"
```

---

## Task 18: Confirmation modal

**Files:**
- Create: `app/views/drafts/confirm.html.slim`
- Create: `app/javascript/controllers/send_confirmation_controller.js`
- Modify: `app/views/drafts/_composer.html.slim` (add the empty turbo_frame for the modal)

**Step 1: View**

```slim
/ app/views/drafts/confirm.html.slim
= turbo_frame_tag "confirm-#{@draft.id}"
  .modal-backdrop data-controller="send-confirmation" data-send-confirmation-cooldown-value="1500"
    .modal-dialog
      h2 Confirm send
      .confirm-row Sending as: #{@draft.sender_alias.name} <#{@draft.sender_alias.email}>
      .confirm-row To: #{@recipient}
      .confirm-row Subject: #{@draft.subject}
      - unless Rails.env.production?
        .dev-warning ⚠ Dev mode — sending to override address.
      p
        | Once sent, the message will be visible to all list subscribers and cannot be unsent.
      .confirm-actions
        = button_to "Cancel", "#", method: :get, class: "button-secondary",
                    data: { action: "click->send-confirmation#cancel" }
        = button_to "Send to #{@recipient}", send_now_draft_path(@draft),
                    method: :post, class: "button-primary",
                    data: { send_confirmation_target: "submit", disabled: true }
```

Add the empty frame to `_composer.html.slim`:
```slim
= turbo_frame_tag "confirm-#{draft.id}"
```

**Step 2: Stimulus controller for cooldown + esc/outside-click**

```javascript
// app/javascript/controllers/send_confirmation_controller.js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values  = { cooldown: Number }
  static targets = ["submit"]

  connect() {
    if (this.hasSubmitTarget) {
      this.submitTarget.disabled = true
      setTimeout(() => { this.submitTarget.disabled = false }, this.cooldownValue || 1500)
    }
    this.boundEsc = this.escClose.bind(this)
    document.addEventListener("keydown", this.boundEsc)
    this.element.addEventListener("click", (e) => { if (e.target === this.element) this.cancel() })
  }

  disconnect() { document.removeEventListener("keydown", this.boundEsc) }

  escClose(e) { if (e.key === "Escape") this.cancel() }

  cancel(e) {
    if (e) e.preventDefault()
    const frame = this.element.closest("turbo-frame")
    if (frame) frame.innerHTML = ""
  }
}
```

**Step 3: Manual verify**

Click Send → modal appears, button disabled for 1.5s, Esc dismisses.

**Step 4: Commit**

```bash
git add app/views/drafts/confirm.html.slim app/javascript/controllers/send_confirmation_controller.js app/views/drafts/_composer.html.slim
git commit -m "feat: send confirmation modal with cooldown"
```

---

## Task 19: Pending badge + system happy-path test

**Files:**
- Modify: `app/views/topics/_message.html.slim`
- Modify: `app/assets/stylesheets/application.css` (or wherever component CSS lives)
- Create: `spec/system/email_sending_spec.rb`

**Step 1: Add badge to message header**

After the `.reply-indicator` block:
```slim
- if message.pending?
  span.pending-badge title="Awaiting list echo"
    i.fa-solid.fa-clock
    | Pending
```

CSS:
```css
.pending-badge { background:#fff7d6; color:#7a5d00; padding:2px 6px; border-radius:4px; font-size:0.85em; }
```

**Step 2: System test**

```ruby
# spec/system/email_sending_spec.rb
require 'rails_helper'

RSpec.describe 'Email sending', type: :system do
  let(:user)     { create(:user) }
  let(:list)     { create(:mailing_list, post_address: 'real@list.example') }
  let(:topic)    { create(:topic, mailing_lists: [list]) }
  let(:parent)   { create(:message, topic: topic) }

  before do
    create(:identity, user: user, email: 'a@b', refresh_token: 'r',
           access_token: 'a', access_token_expires_at: 1.hour.from_now,
           send_authorized_at: Time.current)
    create(:alias, user: user, email: 'a@b', name: 'Alice')
    sign_in_as(user)

    allow(Outgoing::RecipientResolver).to receive(:for).and_return("test@example.com")
    allow(Gmail::SendClient).to receive(:send_raw).and_return({"id" => "g"})
  end

  it 'reply → autosave → confirm → send → pending badge appears' do
    visit topic_path(topic)
    within("[data-message-id='#{parent.id}']") { click_button "Reply" }
    fill_in 'outgoing_draft[body]', with: 'this is my reply'
    expect(page).to have_text('Saved', wait: 5)
    click_button 'Send'
    within('.modal-dialog') do
      expect(page).to have_text('To: test@example.com')
      sleep 1.6
      click_button(/Send to test@example.com/)
    end
    perform_enqueued_jobs
    expect(page).to have_css('.pending-badge', text: 'Pending', wait: 5)
  end
end
```

**Step 3: Run**

```bash
bundle exec rspec spec/system/email_sending_spec.rb
```

**Step 4: Commit**

```bash
git add app/views/topics/_message.html.slim app/assets/stylesheets/ spec/system/email_sending_spec.rb
git commit -m "feat: pending badge + end-to-end system test"
```

---

## Task 20: Admin /admin/outgoing_messages page

**Files:**
- Create: `app/controllers/admin/outgoing_messages_controller.rb`
- Modify: `config/routes.rb` (add `resources :outgoing_messages, only: [:index]` under `namespace :admin`)
- Create: `app/views/admin/outgoing_messages/index.html.slim`
- Create: `spec/requests/admin/outgoing_messages_spec.rb`

**Step 1: Spec**

```ruby
require 'rails_helper'

RSpec.describe 'Admin::OutgoingMessages', type: :request do
  let(:admin) { create(:user, admin: true) }
  before { sign_in_as(admin) }

  it 'lists pending messages and recent sent ones' do
    create(:message, state: 'pending', sent_at: 5.minutes.ago)
    create(:message, state: 'sent',    sent_at: 2.minutes.ago, sent_to_address: 'x@y')
    get '/admin/outgoing_messages'
    expect(response.body).to include('pending')
  end
end
```

**Step 2: Implement**

```ruby
class Admin::OutgoingMessagesController < Admin::BaseController  # or whatever the existing pattern is
  def index
    @pending = Message.pending.order(sent_at: :desc).limit(200)
    @recent  = Message.sent.where.not(sent_via_identity_id: nil).order(sent_at: :desc).limit(200)
  end
end
```

```slim
/ app/views/admin/outgoing_messages/index.html.slim
h1 Outgoing messages

h2 Pending (#{@pending.size})
table
  tr
    th Sent at
    th Subject
    th To
    th Age
  - @pending.each do |m|
    tr
      td = l(m.sent_at, format: :short)
      td = m.subject
      td = m.sent_to_address
      td = "#{((Time.current - m.sent_at) / 60).round} min"

h2 Recent sent (echoed)
table
  tr
    th Sent
    th Subject
    th To
  - @recent.each do |m|
    tr
      td = l(m.sent_at, format: :short)
      td = m.subject
      td = m.sent_to_address
```

**Step 3: Run + commit**

```bash
bundle exec rspec spec/requests/admin/outgoing_messages_spec.rb
git add app/controllers/admin/outgoing_messages_controller.rb app/views/admin/outgoing_messages/ config/routes.rb spec/requests/admin/outgoing_messages_spec.rb
git commit -m "feat: admin page listing pending + recent outgoing messages"
```

---

## Task 21: Observability — `instrument` events

**Files:**
- Modify: `app/jobs/send_outgoing_message_job.rb`
- Modify: `app/services/email_ingestor.rb` (in `update_existing_message`)

**Step 1: Wrap send paths with `instrument`**

```ruby
# in SendOutgoingMessageJob#perform
ActiveSupport::Notifications.instrument("outgoing.send.attempt", draft_id: draft.id)
# on success
ActiveSupport::Notifications.instrument("outgoing.send.success",
  draft_id: draft.id, message_id: msg.id)
# on failure (in rescue)
ActiveSupport::Notifications.instrument("outgoing.send.failure",
  draft_id: draft.id, reason: e.class.name, message: e.message)
```

**Step 2: Wrap echo path**

```ruby
# in EmailIngestor#update_existing_message after the state flip
if updates[:state] == Message::STATE_SENT
  ActiveSupport::Notifications.instrument("outgoing.echo.matched",
    message_id: message.message_id,
    pending_age_seconds: (Time.current - (message.sent_at || message.created_at)).to_i)
end
```

**Step 3: Commit**

```bash
git add app/jobs/send_outgoing_message_job.rb app/services/email_ingestor.rb
git commit -m "chore: structured instrument events for send + echo"
```

---

## Task 22: Final wiring + manual verification

**Step 1: Run the full test suite**

```bash
bundle exec rspec
```
Expected: all green.

**Step 2: Smoke test the dev environment**

```bash
make dev
```

Manual checks:
1. Set `HACKORUM_DEV_REPLY_TO=you@yourhost` in `.env.development` (a personal address).
2. Create at least one mailing list with a `post_address` set to a `*.list.postgresql.org` value.
3. Set `HACKORUM_DEV_REPLY_TO` to that real list address → expect send to fail with `RealListAddressInDevError`.
4. Reset to your personal address, log in via Google, click "Authorize sending" in settings.
5. Open a topic, click Reply on a message, type, see Saved indicator, click Send.
6. Modal appears showing your personal address; wait 1.5s; click Send.
7. Page shows pending badge.
8. Run the IMAP worker against a label that contains the echo (or simulate via `script/simulate_email_once.rb` with the same `Message-Id`) — pending flips to sent.

**Step 3: Update README**

Add a brief section under "Development" titled "Email sending (dev)" explaining the env var requirements and the safety check.

**Step 4: Commit & wrap**

```bash
git add README.md
git commit -m "docs: dev instructions for email sending"
```

Open a PR or merge to main per project workflow.

---

## Acceptance criteria (verify before declaring done)

- [ ] User without authorization sees no Reply button.
- [ ] After authorizing, Reply button appears on every message.
- [ ] Composer autosaves at 2s debounce + on blur.
- [ ] Send button opens a modal showing the resolved recipient verbatim.
- [ ] Confirm button is disabled for 1.5s after modal opens.
- [ ] Esc and outside-click close the modal without sending.
- [ ] Successful send produces a pending Message visible to everyone with a badge.
- [ ] Drafts visible only to author.
- [ ] Failed send (any reason) returns the draft to idle with `last_send_error` shown.
- [ ] Token revoke (4xx from refresh) marks identity revoked locally.
- [ ] In dev, sending without `HACKORUM_DEV_REPLY_TO` is refused.
- [ ] In dev, sending with `HACKORUM_DEV_REPLY_TO` set to a real list address is refused.
- [ ] IMAP echo flips pending → sent without double-counting.
- [ ] Stale `sending` drafts auto-reset after 10 minutes.
- [ ] Admin page lists pending and recent echoed messages.
- [ ] Production deployment configures `RAILS_AR_ENCRYPTION_PRIMARY_KEY` / `RAILS_AR_ENCRYPTION_DETERMINISTIC_KEY` / `RAILS_AR_ENCRYPTION_SALT` (or migrates these into `credentials.yml.enc` and provides `RAILS_MASTER_KEY`). Without this, the first identity save will crash in production.
