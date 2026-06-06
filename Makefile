ENGINE  ?= $(shell command -v podman >/dev/null 2>&1 && echo podman || echo docker)
COMPOSE ?= $(ENGINE) compose --env-file .env.development -f compose.dev.yml

.PHONY: dev dev-detach down shell console test imap logs db-migrate db-reset db-import db-import-legacy mbox-import stats psql sim-email-once sim-email-stream backfill-patch-submissions

dev: ## Start dev stack (foreground)
	$(COMPOSE) up --build

dev-detach: ## Start dev stack in background
	$(COMPOSE) up -d --build

dev-prod-detach: ## Start dev stack but run Rails in production mode (uses dev compose & env)
	RAILS_ENV=production NODE_ENV=production RAILS_SERVE_STATIC_FILES=1 RAILS_LOG_TO_STDOUT=1 FORCE_SSL=false $(COMPOSE) up -d --build

down: ## Stop dev stack
	$(COMPOSE) stop
	rm -f tmp/pids/server.pid

shell: ## Open a shell in the web container
	$(COMPOSE) exec web bash

console: ## Open Rails console in the web container
	$(COMPOSE) exec web bin/rails console

test: ## Run RSpec in the web container (uses test database)
	$(COMPOSE) exec -e RAILS_ENV=test -e DATABASE_URL=postgresql://hackorum:hackorum@db:5432/hackorum_test web bin/rails db:prepare
	$(COMPOSE) exec -e RAILS_ENV=test -e DATABASE_URL=postgresql://hackorum:hackorum@db:5432/hackorum_test web bundle exec rspec $(ARGS)

db-migrate: ## Run db:migrate
	$(COMPOSE) exec web bin/rails db:migrate

db-reset: ## Drop and setup (create/migrate/seed) - stops web if running, restarts after
	@WEB_WAS_RUNNING=$$($(COMPOSE) ps --status running --format '{{.Service}}' | grep -q '^web$$' && echo 1 || echo 0); \
	if [ "$$WEB_WAS_RUNNING" = "1" ]; then \
		echo "Stopping web container..."; \
		$(COMPOSE) stop web; \
	fi; \
	echo "Running db:drop and db:setup..."; \
	$(COMPOSE) run --rm web bin/rails db:drop db:setup; \
	if [ "$$WEB_WAS_RUNNING" = "1" ]; then \
		echo "Restarting web container..."; \
		$(COMPOSE) start web; \
	fi

PSQL_IMPORT = $(COMPOSE) exec -T db bash -lc 'psql -v ON_ERROR_STOP=1 -U $${POSTGRES_USER:-hackorum} -d $${POSTGRES_DB:-hackorum_development}'

db-import: ## Import new-format dumps (env: SCHEMA=/path/schema-YYYY-MM.sql.gz PUBLIC_DATA=/path/public-data-YYYY-MM.sql.gz [PRIVATE_DATA=/path/private-data-YYYY-MM.sql.gz]) - stops web if running, restarts after
	@if [ -z "$(SCHEMA)" ]; then echo "Set SCHEMA=/path/to/schema-YYYY-MM.sql.gz"; exit 1; fi
	@if [ -z "$(PUBLIC_DATA)" ]; then echo "Set PUBLIC_DATA=/path/to/public-data-YYYY-MM.sql.gz"; exit 1; fi
	@if [ ! -f "$(SCHEMA)" ]; then echo "SCHEMA file not found: $(SCHEMA)"; exit 1; fi
	@if [ ! -f "$(PUBLIC_DATA)" ]; then echo "PUBLIC_DATA file not found: $(PUBLIC_DATA)"; exit 1; fi
	@if [ -n "$(PRIVATE_DATA)" ] && [ ! -f "$(PRIVATE_DATA)" ]; then echo "PRIVATE_DATA file not found: $(PRIVATE_DATA)"; exit 1; fi
	@import_file() { \
		if echo "$$1" | grep -qE '\.gz$$'; then \
			gzip -cd "$$1" | $(PSQL_IMPORT); \
		else \
			cat "$$1" | $(PSQL_IMPORT); \
		fi; \
		if [ $$? -ne 0 ]; then echo "$$2 import failed"; return 1; fi; \
	}; \
	WEB_WAS_RUNNING=$$($(COMPOSE) ps --status running --format '{{.Service}}' | grep -q '^web$$' && echo 1 || echo 0); \
	if [ "$$WEB_WAS_RUNNING" = "1" ]; then \
		echo "Stopping web container..."; \
		$(COMPOSE) stop web; \
	fi; \
	echo "Ensuring db container is running..."; \
	$(COMPOSE) up -d db; \
	echo "Waiting for db to accept connections..."; \
	for i in $$(seq 1 60); do \
		if $(COMPOSE) exec -T db bash -lc 'pg_isready -U $${POSTGRES_USER:-hackorum} -d postgres' >/dev/null 2>&1; then break; fi; \
		sleep 1; \
	done; \
	echo "Dropping and recreating database..."; \
	$(COMPOSE) exec -T db bash -lc 'psql -v ON_ERROR_STOP=1 -U $${POSTGRES_USER:-hackorum} -d postgres -c "DROP DATABASE IF EXISTS $${POSTGRES_DB:-hackorum_development};" -c "CREATE DATABASE $${POSTGRES_DB:-hackorum_development};"' || { echo "drop/create failed"; exit 1; }; \
	echo "Importing schema $(SCHEMA)..."; \
	import_file "$(SCHEMA)" schema || exit 1; \
	echo "Importing public data $(PUBLIC_DATA)..."; \
	import_file "$(PUBLIC_DATA)" public-data || exit 1; \
	if [ -n "$(PRIVATE_DATA)" ]; then \
		echo "Importing private data $(PRIVATE_DATA)..."; \
		import_file "$(PRIVATE_DATA)" private-data || exit 1; \
	else \
		echo "No PRIVATE_DATA provided; skipping private data load."; \
	fi; \
	if [ "$$WEB_WAS_RUNNING" = "1" ]; then \
		echo "Restarting web container..."; \
		$(COMPOSE) start web; \
	fi

db-import-legacy: ## Import legacy split dumps (env: DUMP=/path/public-YYYY-MM.sql.gz PDUMP=/path/private-schema-YYYY-MM.sql.gz). Filters cross-dump FKs out of public and reapplies them after private loads.
	@if [ -z "$(DUMP)" ]; then echo "Set DUMP=/path/to/public-YYYY-MM.sql.gz"; exit 1; fi
	@if [ -z "$(PDUMP)" ]; then echo "Set PDUMP=/path/to/private-schema-YYYY-MM.sql.gz"; exit 1; fi
	@if [ ! -f "$(DUMP)" ]; then echo "DUMP file not found: $(DUMP)"; exit 1; fi
	@if [ ! -f "$(PDUMP)" ]; then echo "PDUMP file not found: $(PDUMP)"; exit 1; fi
	@if [ ! -f deploy/backup/private_tables.txt ]; then echo "deploy/backup/private_tables.txt not found"; exit 1; fi
	@if [ ! -f deploy/backup/split_cross_fks.awk ]; then echo "deploy/backup/split_cross_fks.awk not found"; exit 1; fi
	@import_file() { \
		if echo "$$1" | grep -qE '\.gz$$'; then \
			gzip -cd "$$1" | $(PSQL_IMPORT); \
		else \
			cat "$$1" | $(PSQL_IMPORT); \
		fi; \
		if [ $$? -ne 0 ]; then echo "$$2 import failed"; return 1; fi; \
	}; \
	WEB_WAS_RUNNING=$$($(COMPOSE) ps --status running --format '{{.Service}}' | grep -q '^web$$' && echo 1 || echo 0); \
	if [ "$$WEB_WAS_RUNNING" = "1" ]; then \
		echo "Stopping web container..."; \
		$(COMPOSE) stop web; \
	fi; \
	echo "Ensuring db container is running..."; \
	$(COMPOSE) up -d db; \
	echo "Waiting for db to accept connections..."; \
	for i in $$(seq 1 60); do \
		if $(COMPOSE) exec -T db bash -lc 'pg_isready -U $${POSTGRES_USER:-hackorum} -d postgres' >/dev/null 2>&1; then break; fi; \
		sleep 1; \
	done; \
	echo "Dropping and recreating database..."; \
	$(COMPOSE) exec -T db bash -lc 'psql -v ON_ERROR_STOP=1 -U $${POSTGRES_USER:-hackorum} -d postgres -c "DROP DATABASE IF EXISTS $${POSTGRES_DB:-hackorum_development};" -c "CREATE DATABASE $${POSTGRES_DB:-hackorum_development};"' || { echo "drop/create failed"; exit 1; }; \
	PRIVATE_REGEX=$$(grep -E '^[a-z0-9_]+$$' deploy/backup/private_tables.txt | tr '\n' '|' | sed 's/|$$//'); \
	FK_TMP=$$(mktemp); \
	trap 'rm -f "$$FK_TMP"' EXIT; \
	echo "Importing public dump (filtered) from $(DUMP)..."; \
	if echo "$(DUMP)" | grep -qE '\.gz$$'; then DECOMP="gzip -cd $(DUMP)"; else DECOMP="cat $(DUMP)"; fi; \
	$$DECOMP | awk -v t="$$PRIVATE_REGEX" -v fkfile="$$FK_TMP" -f deploy/backup/split_cross_fks.awk \
		| $(PSQL_IMPORT) || { echo "public (filtered) import failed"; exit 1; }; \
	echo "Extracted $$(grep -c '^ALTER TABLE ONLY' $$FK_TMP) cross-dump FK constraints to reapply after private load."; \
	echo "Importing private schema $(PDUMP)..."; \
	import_file "$(PDUMP)" private-schema || exit 1; \
	echo "Reapplying cross-dump FK constraints..."; \
	cat "$$FK_TMP" | $(PSQL_IMPORT) || { echo "cross-FK reapply failed"; exit 1; }; \
	if [ "$$WEB_WAS_RUNNING" = "1" ]; then \
		echo "Restarting web container..."; \
		$(COMPOSE) start web; \
	fi

mbox-import: ## Import mbox files (env: LIST=id MBOX_DIR=/path MBOX_FILES="*.mbox" ARGS="--update-body")
	@if [ -z "$(LIST)" ]; then echo "Set LIST=<mailing-list-identifier>"; exit 1; fi
	@if [ -z "$(MBOX_DIR)" ]; then echo "Set MBOX_DIR=/path/to/mbox/directory"; exit 1; fi
	@if [ -z "$(MBOX_FILES)" ]; then echo "Set MBOX_FILES='*.mbox' or specific filenames"; exit 1; fi
	$(COMPOSE) run --rm \
		-v $(MBOX_DIR):/import:ro,z \
		web bash -c 'ruby script/mbox_import.rb --list $(LIST) $(ARGS) $(addprefix /import/,$(MBOX_FILES))'

stats: ## Rebuild stats (env: GRANULARITY=all|daily|weekly|monthly)
	$(COMPOSE) exec web bundle exec ruby script/build_stats.rb $${GRANULARITY:-all}

psql: ## Open psql against the dev DB
	COMPOSE_PROFILES=tools $(COMPOSE) run --rm psql

imap: ## Start stack with IMAP worker profile
	$(COMPOSE) --profile imap up --build

logs: ## Follow web logs
	$(COMPOSE) logs -f web

sim-email-once: ## Send a single simulated email (env: SENT_OFFSET_SECONDS, EXISTING_ALIAS_PROB, EXISTING_TOPIC_PROB)
	$(COMPOSE) exec web ruby script/simulate_email_once.rb

sim-email-stream: ## Start a continuous simulated email stream (env: MIN_INTERVAL_SECONDS, MAX_INTERVAL_SECONDS, EXISTING_ALIAS_PROB, EXISTING_TOPIC_PROB)
	$(COMPOSE) exec web ruby script/simulate_email_stream.rb

backfill-patch-submissions: ## Recompute messages.is_patch_submission (dry run by default; pass ARGS=--fix to apply)
	$(COMPOSE) exec web ruby script/backfill_patch_submissions.rb $(ARGS)

rubocop: ## Run rubocop
	$(COMPOSE) exec web bundle exec rubocop

brakeman: ## Run brakeman
	$(COMPOSE) exec web bin/brakeman
