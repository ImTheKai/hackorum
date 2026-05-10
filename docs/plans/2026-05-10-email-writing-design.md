# Email Writing for Hackorum — Design

**Date:** 2026-05-10
**Status:** Approved (brainstorming complete; ready for implementation plan)

## Goal

Let users optionally authorize Hackorum to send mailing-list replies via their
Google account using the narrowly-scoped Gmail API. Login and registration
flows remain read-only and unchanged. Drafts persist server-side; pending
messages are visible to everyone with a clear badge until the mailing list
echoes them back through the existing IMAP ingestor.

## Scope

### In scope
- OAuth grant for `gmail.send` (offline access) initiated from Settings.
- Per-message inline reply composer with autosave.
- Plaintext-only body. Subject prefilled and editable.
- Pending → sent state transition driven by IMAP echo via `Message-Id` match.
- Configurable recipient: per-list `post_address` in production; required env
  override in non-production with refusal to send to real list addresses.
- Two-step send confirmation (modal showing actual recipient).
- Token refresh, revocation (local + best-effort Google revoke).

### Out of scope (v1)
- New topic / starting a thread.
- Attachments.
- Reply-all / multiple recipients.
- Editing or unsending a sent or pending message.
- Stuck-pending sweeper (spec'd, deferred to v1.1).
- Non-Google sending providers.

## Constraints

- Gmail API forces `From:` to the OAuth account's email address. Cannot
  impersonate other aliases. Sender alias used in DB always matches the
  authorized Google account.
- Postgres mailing list normally preserves `Message-Id` end-to-end; echo
  matching relies on this. (Edge case noted; not handled in v1.)
- `outgoing_drafts` are private to author. `messages.state=pending` is
  visible to everyone.

## Architecture

```
Browser
  Reply button per message (visible if user has send-authorized identity)
  Inline composer (Stimulus): autosave PATCH /drafts/:id
  Send → confirmation modal → POST /drafts/:id/send → Turbo response

Rails app
  DraftsController (CRUD + send + confirm)
  Settings::SendAuthController (OAuth grant/revoke)
  SendOutgoingMessageJob (solid_queue)
  Gmail::SendClient + OAuth::TokenRefresher
  RecipientResolver
  OutgoingMessageBuilder

Gmail API (gmail.send scope)
  POST gmail.googleapis.com/gmail/v1/users/me/messages/send

List distribution → echo arrives via existing IMAP worker
  EmailIngestor.update_existing_message → flips pending → sent
```

**Invariant:** `state=pending` means Gmail accepted the send; `state=sent`
means the mailing list has echoed it back.

## OAuth flow & token storage

### Two separate flows on the same provider

| Flow      | Trigger                              | Scope                                                  | access_type |
|-----------|--------------------------------------|--------------------------------------------------------|-------------|
| Login/link| `/auth/google_oauth2` (existing)     | `email profile`                                        | online      |
| Send-auth | `/auth/google_oauth2?send=1`         | `email profile https://www.googleapis.com/auth/gmail.send` | offline + `prompt=consent` |

Implemented via omniauth-google-oauth2 dynamic config (`setup` lambda reading
request params at request phase). Initializer-based static scope replaced.

### Callback

`OmniauthCallbacksController#google_oauth2` extended with a `sending` branch:
require `current_user`, capture `credentials.refresh_token`, auto-verify the
alias matching `info.email` on the user (matches existing linking logic),
persist tokens on `Identity`, redirect to settings with notice.

### Storage

Extend `identities`:
- `refresh_token` (text, encrypted via Rails 8 `encrypts`)
- `access_token` (text, encrypted)
- `access_token_expires_at` (datetime)
- `scopes` (text, space-separated)
- `send_authorized_at` (datetime)
- `send_revoked_at` (datetime)
- `last_send_error` (text)

Scope: `Identity.send_authorized` =
`where.not(refresh_token: nil).where(send_revoked_at: nil)`.

### Refresh

Before each send: refresh if `access_token` blank or
`access_token_expires_at < 1.minute.from_now`. Refresh 4xx ⇒ revoke locally
(null tokens, set `send_revoked_at`), surface error on draft, do not retry.

### Revoke

`DELETE /settings/send_auth/:identity_id`:
1. Best-effort `POST https://oauth2.googleapis.com/revoke` with refresh_token.
2. Null token columns + set `send_revoked_at`.

## Data model

### New table `outgoing_drafts`

```ruby
create_table :outgoing_drafts do |t|
  t.references :user,             null: false, foreign_key: true
  t.references :topic,            null: false, foreign_key: true
  t.references :reply_to_message, null: false, foreign_key: { to_table: :messages }
  t.references :sender_alias,     null: false, foreign_key: { to_table: :aliases }
  t.references :identity,         null: false, foreign_key: true
  t.string  :subject,             null: false
  t.text    :body,                null: false, default: ""
  t.string  :status,              null: false, default: "idle"  # idle | sending
  t.text    :last_send_error
  t.datetime :sending_started_at
  t.timestamps
  t.index [:user_id, :reply_to_message_id], unique: true
end
```

- Author-only visibility. Scoped queries.
- No topic-counter callbacks. Drafts never touch `Topic` or `TopicParticipant`.
- `status=sending` blocks autosave PATCH (returns 409) and a second send.
- Stale `sending` rows (`sending_started_at < 10.min.ago`) reset to `idle` by
  a recurring sweep job; allows retry.

### `messages` extensions

```ruby
add_column :messages, :state,                :string,   null: false, default: "sent"
add_column :messages, :sent_at,              :datetime
add_column :messages, :sent_via_identity_id, :bigint
add_column :messages, :sent_to_address,      :string
add_foreign_key :messages, :identities, column: :sent_via_identity_id
add_index :messages, :state
```

- Backfill existing rows to `state="sent"` (default covers it).
- Constants `Message::STATE_PENDING`, `Message::STATE_SENT` (no `enum`).
- Pending rows fire existing `after_create` callbacks (counters,
  `last_message_at`, `topic_participants`). Pending is part of the
  "real" timeline, just badged.

### `mailing_lists` extension

```ruby
add_column :mailing_lists, :post_address, :string  # nullable; required to send
```

### Outgoing `Message-Id`

Generated at send time: `<#{SecureRandom.uuid}@#{ENV.fetch("HACKORUM_OUTGOING_DOMAIN", "hackorum.local")}>`.

### Threading headers (computed at send, not stored)

- `In-Reply-To: <parent.message_id>`
- `References:` walk parent chain via `reply_to`, append parent's `message_id`.

## Send pipeline

### `RecipientResolver`

```ruby
def self.for(topic)
  list = topic.mailing_lists.first  # the list to reply to (typically inferred from parent)
  raise MissingPostAddressError if list.nil? || list.post_address.blank?

  if Rails.env.production?
    list.post_address
  else
    override = ENV["HACKORUM_DEV_REPLY_TO"]
    raise MissingDevOverrideError if override.blank?
    raise RealListAddressInDevError if MailingList.where("lower(post_address) = lower(?)", override).exists?
    override
  end
end
```

Multi-list topics: prefer the list the parent message is associated with via
`message_mailing_lists`; fall back to most recently active list.

### Controller surface

```
resources :outgoing_drafts, path: "drafts", only: [:create, :update, :destroy] do
  member do
    get  :confirm     # renders confirmation modal Turbo Frame
    post :send_now    # transitions status idle→sending and enqueues job
  end
end
namespace :settings do
  resource :send_auth, only: [:show, :destroy]
end
```

### Job

`SendOutgoingMessageJob.perform(draft_id)`:
1. Load draft; bail if not `sending`.
2. Refresh token if needed.
3. Build RFC822 via `OutgoingMessageBuilder` (resolves recipient, generates
   message_id, threading headers).
4. POST to Gmail API.
5. On 200: in a transaction, create `Message(state: "pending", ...)`, destroy
   draft, broadcast Turbo Stream to topic.
6. On `AuthRevokedError` / `PermanentError`: write `last_send_error`, reset
   `status=idle`, broadcast composer replace; revoke locally on auth error.
7. `TransientError`: retry 5× with `wait: :polynomially_longer`.

### `Gmail::SendClient`

Plain `Net::HTTP` POST. Status mapping:
- 200 → success.
- 401 / 403 → `AuthRevokedError`.
- Other 4xx → `PermanentError`.
- 5xx / network → `TransientError`.

### Failure summary

| Failure                       | Handling                                       |
|-------------------------------|------------------------------------------------|
| Token refresh 4xx             | revoke locally, draft.error, no retry          |
| Gmail 401/403                 | revoke locally, draft.error, no retry          |
| Gmail 4xx (other)             | draft.error, no retry, log                     |
| Gmail 5xx / network           | retry 5× exponential, then draft.error         |
| Recipient resolver raises     | draft.error pre-flight (before status=sending) |
| Stuck `status=sending`        | sweep resets after 10 minutes                  |

## UI / UX

### Reply button

Per-message, only rendered when `current_user.can_send_email?` (i.e. has at
least one `Identity.send_authorized`). Triggers Turbo Frame load of composer
below that message.

### Inline composer

```
┌─ composer card ─────────────────────────────────────┐
│ Replying to #3 by alice (you)                       │
│ Sending as: Alice <alice@gmail.com>                 │
│ To: pgsql-hackers@lists.postgresql.org              │
│ Subject: [Re: Topic title____________]              │
│ ┌───────────────────────────────────────────────┐   │
│ │ [textarea — empty]                             │   │
│ └───────────────────────────────────────────────┘   │
│ ⓘ Saved 2s ago                                       │
│ [Send]   [Discard]                                  │
└─────────────────────────────────────────────────────┘
```

- Empty body on open (no auto-quote).
- Subject prefilled `"Re: " + parent.subject.sub(/\A(re|aw|fwd):\s*/i, "")`.
- Stimulus `reply_composer_controller`: autosave debounced 2s + on blur.
  PATCH returns 409 when `status=sending` ⇒ freeze fields.
- State indicator: Saved / Saving… / Save failed / Sending… / Failed.

### Send confirmation (mandatory two-step)

Click `[Send]` opens a server-rendered modal (Turbo Frame from
`/drafts/:id/confirm`):

```
┌─ Confirm send ──────────────────────────────────────────────┐
│ Sending as:  Alice <alice@gmail.com>                        │
│ To:          pgsql-hackers@lists.postgresql.org             │
│ Subject:     Re: Topic title                                │
│                                                              │
│ Once sent, the message will be visible to all list          │
│ subscribers and cannot be unsent.                           │
│                                                              │
│ [Cancel]   [Send to pgsql-hackers@lists.postgresql.org]     │
└──────────────────────────────────────────────────────────────┘
```

- Recipient address shown verbatim (resolved server-side, including dev
  override).
- Confirm button label includes the recipient address.
- 1.5-second cooldown disables the confirm button after modal opens.
- `Esc` and outside-click cancel without submitting.
- In non-production: `⚠ Dev mode — sending to override address` banner.

### Pending badge

```slim
- if message.state == "pending"
  span.pending-badge title="Awaiting list echo"
    i.fa-solid.fa-clock
    | Pending
```

Muted yellow; persists until echo flips state.

### Draft restoration

When a topic is rendered, load `current_user.outgoing_drafts.where(topic: @topic)`.
For each, render the composer open inline with saved content.

### Settings page

Section under Connected Accounts:

```
Email sending
  Status: Authorized as alice@gmail.com
  Authorized: 3 days ago
  Last error: —
  [Revoke authorization]
```

Or, when not authorized:

```
Email sending
  Authorize Hackorum to send replies via your Google account.
  Uses the gmail.send scope (send-only).
  [Authorize sending]
```

## Echo handling (pending → sent)

Extend `EmailIngestor#update_existing_message`: if the matched row has
`state=pending`, set `state=sent` (preserve our `sent_at`). Existing
`associate_mailing_list` call attaches the list join. No counter changes
because counters fired at insert.

**Edge cases (documented, not handled in v1):**
- List rewrites Message-Id ⇒ duplicate row. Mitigation deferred; comment in
  `EmailIngestor`.
- Echo never arrives ⇒ pending forever. v1.1 sweeper to flag stuck pending
  with UI badge.

## Configuration & dev safety

`.env.development.example` additions:
```
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=
HACKORUM_DEV_REPLY_TO=
HACKORUM_OUTGOING_DOMAIN=hackorum.local
```

Hard guards:
- "Authorize sending" button hidden when `GOOGLE_CLIENT_ID` blank.
- Send refused in non-production when `HACKORUM_DEV_REPLY_TO` blank.
- Send refused in non-production when override matches any
  `mailing_lists.post_address`.

## Observability

- Structured `instrument` events: `outgoing.send.attempt`,
  `outgoing.send.success`, `outgoing.send.failure {reason}`,
  `outgoing.echo.matched {pending_age_seconds}`.
- `last_send_error` surfaces in user settings.
- Admin page `/admin/outgoing_messages` listing pending messages by age and
  recently echoed sends.

## Testing

- **Unit:** `OutgoingDraft` validations + uniqueness; `Message` state
  transitions; `EmailIngestor` echo-flip without double counters.
- **Service:** `Gmail::SendClient` per status branch; `OAuth::TokenRefresher`
  paths; `RecipientResolver` (prod, dev-override-set, dev-override-blank,
  dev-override-equals-real-list).
- **Job:** happy path, transient retry, permanent fail, auth revoked.
- **Controller:** autosave 409 when sending; send_now 409 when not idle;
  uniqueness on create.
- **System (Capybara):** authorize (stubbed), reply, autosave, send,
  confirmation modal, see "Sending…", stub Gmail 200, see pending message,
  ingest raw echo, see state→sent.
- **Security:** drafts not readable/updatable/destroyable/sendable by
  non-author.
- **OAuth callback:** `?send=1` requests `gmail.send + offline + consent`;
  default flow unchanged.

## Loose ends (decisions)

| Item                                | Decision                                                 |
|-------------------------------------|----------------------------------------------------------|
| Multiple Google identities per user | Allowed; pick most recently authorized for sending       |
| HTML in body                        | Stripped at draft save                                   |
| Body length cap                     | Soft 100k chars at controller                            |
| Rate limit                          | Defer; rely on Gmail API quotas                          |
| New topic                           | Out of scope                                             |
| Attachments                         | Out of scope                                             |
| Reply-all                           | Out of scope                                             |
| Editing pending/sent                | Not supported                                            |
| Multiple post_addresses per list    | Not supported (`post_address` is `string`)               |
