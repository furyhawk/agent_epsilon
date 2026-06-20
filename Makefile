.PHONY: install format lint test run clean help db-init dev dev-down dev-logs dev-rebuild dev-frontend docker-clean stage stage-down prod prod-down

# ── Container runtime detection (Docker / Podman) ─────────────────────────
# Uses Docker if available, otherwise falls back to Podman.
DOCKER := $(shell command -v docker 2>/dev/null || command -v podman 2>/dev/null)
DOCKER_COMPOSE := $(shell command -v docker-compose 2>/dev/null || (command -v docker 2>/dev/null && echo "docker compose") || (command -v podman 2>/dev/null && echo "podman compose"))


# === Environments ===========================================================
# `make dev`   — local development (docker-compose.dev.yml + bind-mounted source)
# `make stage` — staging (docker-compose.yml — built images, no live reload)
# `make prod`  — production (docker-compose.prod.yml — needs backend/.env + nginx)
# Each env has matching -down / -logs / -rebuild siblings.

# Wait for postgres to accept connections. Polls pg_isready instead of a
# fixed sleep — handles slow startups and cold-start image pulls.
define _wait_for_db
	@echo "Waiting for PostgreSQL ($(1))..."
	@for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do \
		if $(DOCKER_COMPOSE) -f $(1) exec -T db pg_isready -U postgres >/dev/null 2>&1; then \
			echo "  ✅ DB ready"; exit 0; \
		fi; \
		printf '.'; sleep 2; \
	done; \
	echo "  ❌ DB not ready after 30s — check 'make dev-logs'"; exit 1
endef

# Fold the opt-in "antv" profile into `make dev` so the diagram sidecar starts
# automatically alongside db/app. The agent connects only when ENABLE_ANTV_CHARTS=true.
COMPOSE_DEV_PROFILES := --profile antv

# === Local dev: build → up → migrate ===
# Idempotent — re-run anytime. Migrations are no-ops when already at head;
# admin seeding is a separate target (`make seed`) so re-running `make dev`
# doesn't keep retrying user creation.
dev:
	@echo "▶ Building backend image…"
	$(DOCKER_COMPOSE) -f docker-compose.dev.yml build app
	@echo "▶ Starting services…"
	@if ! $(DOCKER_COMPOSE) -f docker-compose.dev.yml $(COMPOSE_DEV_PROFILES) up -d; then \
		echo ""; \
		echo "⚠ First start failed. Tearing down stale containers and retrying once…"; \
		echo "  (volumes preserved — DB data is safe; use 'make clean' for a full wipe)"; \
		$(DOCKER_COMPOSE) -f docker-compose.dev.yml down --remove-orphans; \
		$(DOCKER_COMPOSE) -f docker-compose.dev.yml $(COMPOSE_DEV_PROFILES) up -d; \
	fi
	$(call _wait_for_db,docker-compose.dev.yml)
	@echo "▶ Applying migrations…"
	$(DOCKER_COMPOSE) -f docker-compose.dev.yml exec -T app agent_epsilon db upgrade
	@echo ""
	@echo "🚀 Dev stack ready:"
	@echo "   API:      http://localhost:8000"
	@echo "   Docs:     http://localhost:8000/docs"
	@echo "   Admin:    http://localhost:8000/admin"
	@echo "   Frontend: http://localhost:3000  (run 'make dev-frontend' or 'cd frontend && bun dev')"
	@echo ""
	@echo "First time? Run 'make seed' to create the default admin user."

# === First-time setup: seed default admin user (one-shot) ===
# Skipped when admin@example.com already exists. Safe to run again — exits
# clean either way. Replace email/password before deploying anywhere real.
seed:
	@echo "▶ Seeding admin user (admin@example.com / admin123)…"
	@if $(DOCKER_COMPOSE) -f docker-compose.dev.yml exec -T app \
		agent_epsilon user list 2>/dev/null \
		| grep -q "admin@example.com"; then \
		echo "  (admin@example.com already exists — nothing to do)"; \
	else \
		$(DOCKER_COMPOSE) -f docker-compose.dev.yml exec -T app \
			agent_epsilon user create \
				--email admin@example.com --password admin123 --superuser \
		&& echo "  ✅ Admin created. Login at http://localhost:8000/admin"; \
	fi

# Convenience: bootstrap a fresh checkout end-to-end.
bootstrap: dev seed

dev-down:
	$(DOCKER_COMPOSE) -f docker-compose.dev.yml $(COMPOSE_DEV_PROFILES) down

# Full wipe — containers, networks, AND volumes. Use after a corrupted state
# (e.g. detached networks, port conflicts that left orphans). DESTROYS DB data.
docker-clean:
	@echo "▶ Removing containers, networks, AND volumes for the dev stack…"
	@echo "  ⚠️  This deletes all local DB data and uploaded files."
	$(DOCKER_COMPOSE) -f docker-compose.dev.yml $(COMPOSE_DEV_PROFILES) down -v --remove-orphans
	@echo "✅ Cleaned. Run 'make dev' to start fresh."

dev-logs:
	$(DOCKER_COMPOSE) -f docker-compose.dev.yml $(COMPOSE_DEV_PROFILES) logs -f

dev-rebuild:
	$(DOCKER_COMPOSE) -f docker-compose.dev.yml build --no-cache app
	$(DOCKER_COMPOSE) -f docker-compose.dev.yml up -d --force-recreate app
dev-frontend:
	$(DOCKER_COMPOSE) -f docker-compose.frontend.yml up -d
	@echo ""
	@echo "✅ Frontend at http://localhost:3000  (backend must be up — 'make dev')"

# === Staging: built images, no bind mounts (production-like, local DB) ===
stage:
	$(DOCKER_COMPOSE) -f docker-compose.yml up -d --build
	$(call _wait_for_db,docker-compose.yml)
	$(DOCKER_COMPOSE) -f docker-compose.yml exec -T app agent_epsilon db upgrade
	@echo "✅ Staging stack at http://localhost:8000"

stage-down:
	$(DOCKER_COMPOSE) -f docker-compose.yml down

# === Production: external Nginx, real secrets in backend/.env ===
prod:
	@test -f backend/.env || (echo "❌ backend/.env missing — run 'cp backend/.env.example backend/.env' and fill in real secrets" && exit 1)
	$(DOCKER_COMPOSE) --env-file backend/.env -f docker-compose.prod.yml up -d --build
	@echo "▶ Waiting for DB then running migrations…"
	@sleep 5
	$(DOCKER_COMPOSE) --env-file backend/.env -f docker-compose.prod.yml exec -T app agent_epsilon db upgrade
	@echo "✅ Production stack up. Configure your nginx host with nginx/nginx.conf"

prod-down:
	$(DOCKER_COMPOSE) --env-file backend/.env -f docker-compose.prod.yml down

prod-logs:
	$(DOCKER_COMPOSE) --env-file backend/.env -f docker-compose.prod.yml logs -f

# Legacy alias
quickstart: dev

# === Setup ===
install:
	uv sync --directory backend --dev
	@echo ""
	@echo "✅ Installation complete!"
	@echo ""
	@echo "Next steps:"
	@echo "  • make docker-db        # Start PostgreSQL"
	@echo "  • make db-upgrade       # Apply migrations"
	@echo "  • make run              # Start development server"
	@echo ""
	@echo "Note: backend/.env is pre-configured for development"

# === Code Quality ===
format:
	uv run --directory backend ruff format app tests cli
	uv run --directory backend ruff check app tests cli --fix

lint:
	uv run --directory backend ruff check app tests cli
	uv run --directory backend ruff format app tests cli --check
	uv run --directory backend ty check

# === Testing ===
test:
	uv run --directory backend pytest tests/ -v

test-cov:
	uv run --directory backend pytest tests/ -v --cov=app --cov-report=html --cov-report=term-missing

# === Database ===
db-init: docker-db
	@echo "Waiting for PostgreSQL to be ready..."
	@sleep 8
	cd backend && uv run agent_epsilon db migrate -m "initial" || true
	cd backend && uv run agent_epsilon db upgrade
	@echo ""
	@echo "✅ Database initialized!"

db-migrate:
	@read -p "Migration message: " msg; \
	uv run --directory backend agent_epsilon db migrate -m "$$msg"

db-upgrade:
	uv run --directory backend agent_epsilon db upgrade

db-downgrade:
	uv run --directory backend agent_epsilon db downgrade

db-current:
	uv run --directory backend agent_epsilon db current

db-history:
	uv run --directory backend agent_epsilon db history

# === Server ===
run:
	uv run --directory backend agent_epsilon server run --reload

run-prod:
	uv run --directory backend agent_epsilon server run --host 0.0.0.0 --port 8000

routes:
	uv run --directory backend agent_epsilon server routes

# === Users ===
create-admin:
	@echo "Creating admin user..."
	uv run --directory backend agent_epsilon user create-admin

user-create:
	uv run --directory backend agent_epsilon user create

user-list:
	uv run --directory backend agent_epsilon user list

# === Taskiq ===
taskiq-worker:
	uv run --directory backend agent_epsilon taskiq worker

taskiq-scheduler:
	uv run --directory backend agent_epsilon taskiq scheduler

# === Docker: Backend (Development) ===
docker-up:
	$(DOCKER_COMPOSE) build app
	$(DOCKER_COMPOSE) up -d
	@echo ""
	@echo "✅ Backend services started!"
	@echo "   API: http://localhost:8000"
	@echo "   Docs: http://localhost:8000/docs"
	@echo "   PostgreSQL: localhost:5432"
	@echo "   Redis: localhost:6379"

docker-down:
	$(DOCKER_COMPOSE) down
	$(DOCKER_COMPOSE) -f docker-compose.frontend.yml down 2>/dev/null || true

docker-logs:
	$(DOCKER_COMPOSE) logs -f

docker-build:
	$(DOCKER_COMPOSE) build

docker-shell:
	$(DOCKER_COMPOSE) exec app /bin/bash

# === Docker: Frontend (Development) ===
docker-frontend:
	$(DOCKER_COMPOSE) -f docker-compose.frontend.yml up -d
	@echo ""
	@echo "✅ Frontend started!"
	@echo "   URL: http://localhost:3000"
	@echo ""
	@echo "Note: Backend must be running (make docker-up)"

docker-frontend-down:
	$(DOCKER_COMPOSE) -f docker-compose.frontend.yml down

docker-frontend-logs:
	$(DOCKER_COMPOSE) -f docker-compose.frontend.yml logs -f

docker-frontend-build:
	$(DOCKER_COMPOSE) -f docker-compose.frontend.yml build

# === Docker: Production (with Traefik) ===
docker-prod:
	$(DOCKER_COMPOSE) -f docker-compose.prod.yml up -d
	@echo ""
	@echo "✅ Production services started with Traefik!"
	@echo ""
	@echo "Endpoints (replace DOMAIN with your domain):"
	@echo "   Frontend: https://$$DOMAIN"
	@echo "   API: https://api.$$DOMAIN"
	@echo "   Traefik: https://traefik.$$DOMAIN"

docker-prod-down:
	$(DOCKER_COMPOSE) -f docker-compose.prod.yml down

docker-prod-logs:
	$(DOCKER_COMPOSE) -f docker-compose.prod.yml logs -f

docker-prod-build:
	$(DOCKER_COMPOSE) -f docker-compose.prod.yml build

# === Docker: Individual Services ===
docker-db:
	$(DOCKER_COMPOSE) up -d db
	@echo ""
	@echo "✅ PostgreSQL started on port 5432"
	@echo "   Connection: postgresql://postgres:postgres@localhost:5432/agent_epsilon"

docker-db-stop:
	$(DOCKER_COMPOSE) stop db

docker-redis:
	$(DOCKER_COMPOSE) up -d redis
	@echo ""
	@echo "✅ Redis started on port 6379"

docker-redis-stop:
	$(DOCKER_COMPOSE) stop redis

# === Vercel (Frontend Deployment) ===
vercel-deploy:
	cd frontend && npx vercel --prod
	@echo ""
	@echo "✅ Frontend deployed to Vercel!"
	@echo "   Set environment variables in Vercel dashboard:"
	@echo "   BACKEND_URL=https://api.your-domain.com"
	@echo "   BACKEND_WS_URL=wss://api.your-domain.com"
	@echo "   NEXT_PUBLIC_AUTH_ENABLED=true"
	@echo "   NEXT_PUBLIC_RAG_ENABLED=true"

# === Cleanup ===
clean:
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name .pytest_cache -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name .ruff_cache -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name .ty_cache -exec rm -rf {} + 2>/dev/null || true
	rm -rf htmlcov/ .coverage coverage.xml

# === Help ===
help:
	@echo ""
	@echo "agent_epsilon - Available Commands"
	@echo "======================================"
	@echo ""
	@echo "🚀 Bootstrap (first-time setup):"
	@echo "  make bootstrap      'make dev' + 'make seed' — full setup from a fresh clone"
	@echo ""
	@echo "Day-to-day dev:"
	@echo "  make dev            Build + start dev stack + apply migrations (idempotent)"
	@echo "  make seed           One-shot admin seed (admin@example.com / admin123)"
	@echo "  make dev-down       Stop dev stack"
	@echo "  make dev-logs       Tail dev container logs"
	@echo "  make dev-rebuild    Force-rebuild backend image"
	@echo "  make docker-clean   Wipe containers + networks + volumes (DESTROYS data)"
	@echo "  make dev-frontend   Start frontend container (after 'make dev')"
	@echo ""
	@echo "📦 Other environments:"
	@echo "  make stage          Production-like stack on localhost (no bind mounts)"
	@echo "  make prod           Production stack (requires backend/.env + nginx)"
	@echo ""
	@echo "Setup (without Docker):"
	@echo "  make install       Install Python deps + pre-commit hooks"
	@echo ""
	@echo "Development:"
	@echo "  make run           Start dev server (with hot reload)"
	@echo "  make test          Run tests"
	@echo "  make lint          Check code quality"
	@echo "  make format        Auto-format code"
	@echo ""
	@echo "Database:"
	@echo "  make db-init       Initialize database (start + migrate)"
	@echo "  make db-migrate    Create new migration"
	@echo "  make db-upgrade    Apply migrations"
	@echo "  make db-downgrade  Rollback last migration"
	@echo "  make db-current    Show current migration"
	@echo ""
	@echo "Users:"
	@echo "  make create-admin  Create admin user (for SQLAdmin access)"
	@echo "  make user-create   Create new user (interactive)"
	@echo "  make user-list     List all users"
	@echo ""
	@echo "RAG:"
	@echo "  uv run agent_epsilon rag-ingest <path> -c <collection>  Ingest files"
	@echo "  uv run agent_epsilon rag-search <query> -c <collection>  Search"
	@echo "  uv run agent_epsilon rag-collections                     List collections"
	@echo "  uv run agent_epsilon rag-sources                         List sync sources"
	@echo "  uv run agent_epsilon rag-source-add                      Add sync source"
	@echo "  uv run agent_epsilon rag-source-sync <id>                Trigger sync"
	@echo ""
	@echo "Taskiq:"
	@echo "  make taskiq-worker     Start Taskiq worker"
	@echo "  make taskiq-scheduler  Start Taskiq scheduler"
	@echo ""
	@echo "Docker (Development):"
	@echo "  make docker-up            Start backend services"
	@echo "  make docker-down          Stop all services"
	@echo "  make docker-logs          View backend logs"
	@echo "  make docker-build         Build backend images"
	@echo "  make docker-frontend      Start frontend (separate)"
	@echo "  make docker-frontend-down Stop frontend"
	@echo "  make docker-db            Start only PostgreSQL"
	@echo "  make docker-redis         Start only Redis"
	@echo ""
	@echo "Docker (Production with Traefik):"
	@echo "  make docker-prod          Start production stack"
	@echo "  make docker-prod-down     Stop production stack"
	@echo "  make docker-prod-logs     View production logs"
	@echo ""
	@echo "Other:"
	@echo "  make routes        Show all API routes"
	@echo "  make clean         Clean cache files"
	@echo ""
