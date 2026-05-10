# Hackorum

Rails 8 app backed by Postgres. Use the containerised development setup below for a quick start; production deploy lives under `deploy/` with its own `README`.

Live application is available at https://hackorum.dev

## Development

Both Docker and Podman (rootless) are supported. The Makefile auto-detects which runtime is available (preferring Podman). Override with `ENGINE=docker` or `ENGINE=podman`.

1) Copy the sample env and adjust as needed:
```bash
cp .env.development.example .env.development
```
2) Build and start the stack (web + Postgres):
```bash
make dev
```
* App: http://localhost:3000
* Postgres: localhost:15432 (user/password: hackorum/hackorum by default)
* Emails sent by the application use `letter_opener`, will be opened by the browser automatically
* If you run into a Postgres data-dir warning, clear the old volume: `docker volume rm hackorum_db-data` (or `podman volume rm hackorum_db-data`)

Useful commands:
* Shell: `make shell`
* Rails console: `make console`
* Migrations/seeds: `make db-migrate` (or run arbitrary commands via `make shell`)
* Tests: `make test`
* Import a public DB dump: `make db-import DUMP=/path/to/public-YYYY-MM.sql.gz`
* If you need private table definitions too, apply `private-schema-YYYY-MM.sql.gz` after the import:
  `gzip -cd /path/to/private-schema-YYYY-MM.sql.gz | make psql`
* Other targets: `make dev-detach` / `make down` / `make logs` / `make db-reset` / `make psql`

Public database dumps (schema + public data) are published at https://dumps.hackorum.dev/

### Incoming email simulator

There are two helper scripts `script/simulate_email_once.rb` and `simulate_email_stream.rb` that simulate incoming emails.
The scripts can be configured by a few environment variables, for details see the source of the scripts.

Makefile shortcuts:
* `make sim-email-once`
* `make sim-email-stream`

### IMAP worker

The "production" IMAP worker which pulls actual mailing list messages from an IMAP label can be also run locally.

```bash
make imap
```
Configure IMAP via `.env.development` (`IMAP_USERNAME`, `IMAP_PASSWORD`, `IMAP_MAILBOX_LABEL`, `IMAP_HOST`, `IMAP_PORT`, `IMAP_SSL`).

Host, Port and ssl settings default to the gmail imap server.

The imap worker will connect to the specified imap, fetch all messages with the given label, import them to the database, and mark them as "read" on the server.
It should point to a label subscribed to the pg-hackers list.
It can't be INBOX, it has to be a specific label.

### Email sending (dev)

Hackorum can send mailing-list replies via the Gmail API on behalf of users
who have opted in from `/settings/account` ("Authorize sending"). The send
pipeline uses the narrowly-scoped `gmail.send` OAuth scope and stores the
refresh token encrypted on the `identities` table.

Required environment variables in `.env.development`:

```
GOOGLE_CLIENT_ID=          # OAuth client id (any test project works)
GOOGLE_CLIENT_SECRET=      # OAuth client secret
HACKORUM_DEV_REPLY_TO=     # required: where outgoing replies actually go in dev
HACKORUM_OUTGOING_DOMAIN=  # optional, defaults to hackorum.local; used in Message-Id

# Active Record encryption keys (32+ char strings)
RAILS_AR_ENCRYPTION_PRIMARY_KEY=
RAILS_AR_ENCRYPTION_DETERMINISTIC_KEY=
RAILS_AR_ENCRYPTION_SALT=
```

Generate AR encryption values with `bin/rails runner 'puts SecureRandom.alphanumeric(32)'`.

**Safety guard**: in non-production, the recipient resolver refuses to send
when `HACKORUM_DEV_REPLY_TO` is unset, and refuses (raises) when its value
matches any real list's `post_address`. Always point it at a personal
mailbox you control during dev. Production uses `mailing_lists.post_address`
directly.

Drafts that get stuck in `status="sending"` for more than 10 minutes are
auto-reset to `idle` by `ResetStaleSendingDraftsJob` (recurring every 5
minutes via `solid_queue`).

Pending messages (Gmail accepted, awaiting list echo) appear with a yellow
"Pending" badge until the IMAP worker ingests the echo and `EmailIngestor`
flips them to `state="sent"`. Admins can inspect the pipeline at
`/admin/outgoing_messages`.

## Production
See `deploy/README.md` for the single-host Docker Compose deployment (Puma + Caddy + Postgres + backups).
