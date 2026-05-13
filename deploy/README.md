# Deployment (single VPS, Docker Compose)

This is a minimal, single-host setup for running Hackorum on a VPS (e.g., Hetzner) with Docker Compose. It includes:
- Web app (Rails / Puma)
- IMAP runner (continuous)
- Postgres
- Caddy for TLS / reverse proxy
- Umami analytics (self-hosted)
- Autoheal watchdog to restart unhealthy containers
- Monthly SQL dumps (public + private split)

## Prerequisites
- Docker + Docker Compose v2 on the VPS
- A domain pointing to the VPS (for Caddy/HTTPS)
- Enough disk for Postgres data + monthly dumps

## Setup steps
1) Copy env template and fill in secrets:
   ```bash
   cp deploy/.env.example deploy/.env
   # edit deploy/.env (SECRET_KEY_BASE, IMAP creds, etc.)
   ```

2) Copy and tune Postgres config:
   ```bash
   cp deploy/postgres/postgresql.conf.example deploy/postgres/postgresql.conf
   # edit deploy/postgres/postgresql.conf to match host resources
   ```

3) Update Caddyfile domain:
   - Edit `deploy/Caddyfile` and replace `hackorum.example.com` and contact email.
   - Ensure the Umami host is set to `umami.hackorum.dev` (see `deploy/Caddyfile.example`).
   - Optional: add `dumps.hackorum.dev` to serve public dumps (see `deploy/Caddyfile.example`).

4) Configure Umami analytics:
   - Set `UMAMI_APP_SECRET` and `UMAMI_HASH_SALT` in `deploy/.env`.
   - Set `UMAMI_DB_USER` and `UMAMI_DB_PASSWORD` for the dedicated Umami database user.
   - Confirm `UMAMI_DATABASE_URL` points at the shared Postgres service.

5) Build and start:
   ```bash
   cd deploy
   docker compose up -d --build
   ```
   Services:
   - `web`: Rails/Puma on port 3000 (internal)
   - `imap_worker`: continuous IMAP ingest
  - `db`: Postgres 18
   - `caddy`: TLS + reverse proxy on :80/:443
   - `umami`: self-hosted analytics UI/API on port 3000 (internal)
   - `autoheal`: restarts containers whose healthchecks fail

6) Verify:
   - Browse to your domain; or `curl -f http://localhost:3000/up` from the host (`docker compose exec web ...` inside the network).

## Observability
- Query stats: pg_stat_statements is preloaded via the Postgres config and created on first init via `/docker-entrypoint-initdb.d/01_pg_stat_statements.sql`. For existing databases, run `CREATE EXTENSION IF NOT EXISTS pg_stat_statements;` once. PgHero is available at `/pghero` for signed-in admin users.
- Request-level profiling: rack-mini-profiler is available; in production it renders only for signed-in admin users.

## Analytics (Umami, self-hosted)
Umami runs as a separate service and uses the same Postgres container (recommended: separate database).

Initialization:
- Fresh install: the init script creates the Umami database (`UMAMI_DB`, default `umami`) on first Postgres boot.
- Existing database: create it once manually (adjust user/db if needed):
  ```bash
  docker compose exec db psql -U postgres -d postgres -c "CREATE ROLE umami LOGIN PASSWORD 'change-me';"
  docker compose exec db psql -U postgres -d postgres -c "CREATE DATABASE umami OWNER umami;"
  ```

Access:
- Add a dedicated hostname in Caddy (example in `deploy/Caddyfile.example`).
- Visit `https://umami.hackorum.dev` and log in (default `admin` / `umami`, then change the password).
- Create a website in Umami and copy the `website_id` into `UMAMI_WEBSITE_ID` in `deploy/.env`.

## Environment variables (deploy/.env)
- `SECRET_KEY_BASE` (required)
- `RAILS_MASTER_KEY` (required — see [Credentials & encryption](#credentials--encryption))
- `APP_HOST` (required — host used by Caddy and mailer URLs)
- `DATABASE_URL` (defaults to local Postgres via env interpolation)
- `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` (for the db container)
- `HACKORUM_DATABASE_PASSWORD` (app DB password)
- Umami:
  - `UMAMI_DB` (database name for init script; default `umami`)
  - `UMAMI_DB_USER` (dedicated Umami database user)
  - `UMAMI_DB_PASSWORD` (dedicated Umami database password)
  - `UMAMI_APP_SECRET` (required, 32+ random hex chars recommended)
  - `UMAMI_HASH_SALT` (required, 32+ random hex chars recommended)
  - `UMAMI_DATABASE_URL` (defaults to local Postgres with `UMAMI_DB`)
  - `UMAMI_WEBSITE_ID` (required for client-side tracking)
  - `UMAMI_HOST` (optional override; defaults to https://umami.hackorum.dev)
- IMAP:
  - `IMAP_USERNAME`, `IMAP_PASSWORD`, `IMAP_MAILBOX_LABEL`
  - Optional: `IMAP_HOST`, `IMAP_PORT`, `IMAP_SSL`
- Gmail OAuth (Google sign-in + per-user "send email"):
  - `GOOGLE_CLIENT_ID`
  - `GOOGLE_CLIENT_SECRET`
  - `GOOGLE_REDIRECT_URI` (e.g., https://your-domain/auth/google_oauth2/callback)
  - See [Gmail send authorization](#gmail-send-authorization) for required scope and
    Google Cloud Console publishing status.
- Transactional mail (Mailgun SMTP — used for password reset, email verification, etc.;
  user-to-thread replies go out via Gmail API, not SMTP):
  - `MAIL_DOMAIN`, `MAIL_FROM`
  - `SMTP_ADDRESS`, `SMTP_PORT`, `SMTP_DOMAIN`, `SMTP_USERNAME`, `SMTP_PASSWORD`
- Puma / job runner:
  - `WEB_CONCURRENCY` (default `3`), `RAILS_MAX_THREADS` (default `5`)
  - `SOLID_QUEUE_IN_PUMA=1` is set in `docker-compose.yml` and is required —
    `SendOutgoingMessageJob` and the every-5-min `ResetStaleSendingDraftsJob`
    run inside the `web` container's Puma process. Do not disable.
- Rails runtime: `RAILS_ENV=production`, `RAILS_LOG_TO_STDOUT=1`, `RAILS_SERVE_STATIC_FILES=1`

## Credentials & encryption
The app stores per-user Gmail OAuth tokens (`Identity#refresh_token`,
`Identity#access_token`) using Active Record Encryption. The encryption keys
live in `config/credentials.yml.enc` and are decrypted at boot using
`RAILS_MASTER_KEY`.

The master key MUST NOT live inside the Docker image:
- `config/master.key` is in `.gitignore` (so it isn't committed) and in
  `.dockerignore` (so a local build cannot bake it into the image).
- On the deploy host, set `RAILS_MASTER_KEY` in `deploy/.env` instead. The
  `web` and `imap_worker` services read it from `.env`.

First-time setup (run once, from a checkout with the existing master key):
```bash
bin/rails db:encryption:init
# prints three keys under "active_record_encryption:" — copy them
EDITOR=vi bin/rails credentials:edit
# paste the three keys, save, and commit the resulting credentials.yml.enc
```

Then on each deploy host, put the master key in `deploy/.env`:
```
RAILS_MASTER_KEY=<contents of config/master.key>
```

Losing `RAILS_MASTER_KEY` makes all stored OAuth tokens permanently
unreadable — the send job will mark the affected drafts as failed with
"Stored token could not be decrypted" and revoke the identity's send
authorization, forcing each user to re-consent. Back up the master key
out-of-band (password manager / secrets vault), not in this repo.

## Gmail send authorization
Reply-sending uses the Gmail API per signed-in user, not SMTP. Each user goes
through a second OAuth consent (offline access, `gmail.send` scope) before they
can send. In the Google Cloud Console for the OAuth client referenced by
`GOOGLE_CLIENT_ID`:
- Add `https://www.googleapis.com/auth/gmail.send` to the configured scopes
  (in addition to the default `email`/`profile` used for sign-in).
- Ensure the OAuth consent screen is set to **In production** (verified).
  While the app is still in **Testing**, refresh tokens for the `gmail.send`
  scope expire after 7 days, after which queued sends fail with
  `Gmail::AuthRevokedError` and the user must re-authorize.
- The send feature is gated by a DB-backed feature flag managed under
  `/admin/features` — no env var is required to enable it, but it is off by
  default for new users.

## Backups (monthly SQL dumps)
The database dumps are split into public and private data, written to a Docker volume mounted at `/dumps` inside the Postgres container. Each month overwrites the same two files:
- `public/public-YYYY-MM.sql.gz` (full schema + data, excluding private tables)
- `public/private-schema-YYYY-MM.sql.gz` (schema-only for private tables)
- `private/private-YYYY-MM.sql.gz` (data-only for private tables)

The table list lives in `deploy/backup/private_tables.txt` and is used for both dumps.
If you enable the `dumps.hackorum.dev` site in Caddy, only `/dumps/public` is mounted read-only in the Caddy container, so private dumps remain inaccessible.

Run (from `deploy/`):
```bash
./backup/run_monthly_dumps.sh
```
Recommended cadence:
- Run monthly (or more often if you want fresher dev data).

Example crontab (runs at 02:15 on the 1st of each month):
```bash
15 2 1 * * cd /path/to/hackorum/deploy && ./backup/run_monthly_dumps.sh >> /var/log/hackorum-dumps.log 2>&1
```

## Initial archive import (mbox)
If you need to import the historical mailing list archive before running the app:

1) Start only Postgres:
   ```bash
   cd deploy
   docker compose up -d db
   ```
2) Run the importer (mount your mbox locally). Replace `/path/to/archive.mbox` with your file:
   ```bash
   docker compose run --rm \
     -e RAILS_ENV=production \
     -v /path/to/archive.mbox:/tmp/archive.mbox \
     web bundle exec ruby script/mbox_import.rb /tmp/archive.mbox
   ```
3) Link contributors (optional but recommended if you have contributor metadata):
   ```bash
   docker compose run --rm \
     -e RAILS_ENV=production \
     web bundle exec ruby script/link_contributors.rb
   ```

4) After import completes, start the rest:
   ```bash
   docker compose up -d web imap_worker caddy autoheal
   ```
   Ensure the same env in `deploy/.env` is present so the importer can connect to the DB.

## Health and watchdog
- Containers have healthchecks. `autoheal` will restart ones labeled `autoheal=true` when unhealthy.
- `restart: unless-stopped` is enabled for long-lived services.

## Deploying updates
```bash
cd deploy
docker compose pull   # if pulling from a registry later
docker compose up -d --build
```

## Notes / future improvements
- Swap local dumps for remote object storage later if needed.
- Add log shipping/metrics if needed; for now Docker logs go to the host.
