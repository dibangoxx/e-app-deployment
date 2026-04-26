###############################################################################
# FlashInfo — Local Development Makefile
# Usage: make <target>
###############################################################################

.PHONY: help up down logs ps shell-api shell-db test lint migrate seed clean reset tf-bootstrap-backend local-db-init local-up

COMPOSE = docker compose
API_SVC  = api
WEB_SVC  = web

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# ── Start / Stop ──────────────────────────────────────────────────────────────
up: ## Start the full stack (detached)
	@cp -n .env.local .env 2>/dev/null || true
	@chmod +x scripts/localstack-init.sh
	$(COMPOSE) up -d --build
	@echo ""
	@echo "  ✅  FlashInfo stack is up!"
	@echo ""
	@echo "  🌐  Frontend        → http://localhost:3000"
	@echo "  🔌  API             → http://localhost:3001"
	@echo "  🏥  Health check    → http://localhost:3001/health"
	@echo "  🗄️   Adminer (DB)   → http://localhost:8080"
	@echo "  🔴  Redis UI        → http://localhost:8081"
	@echo "  🔍  OpenSearch UI   → http://localhost:5601"
	@echo "  ☁️   LocalStack      → http://localhost:4566"
	@echo ""

up-core: ## Start only core services (postgres, redis, localstack) — no app containers
	@cp -n .env.local .env 2>/dev/null || true
	@chmod +x scripts/localstack-init.sh
	$(COMPOSE) up -d postgres redis localstack opensearch

down: ## Stop all services
	$(COMPOSE) down

down-volumes: ## Stop all services AND delete all data volumes
	$(COMPOSE) down -v

# ── Logs ──────────────────────────────────────────────────────────────────────
logs: ## Tail logs from all services
	$(COMPOSE) logs -f

logs-api: ## Tail API logs only
	$(COMPOSE) logs -f $(API_SVC)

logs-web: ## Tail web logs only
	$(COMPOSE) logs -f $(WEB_SVC)

# ── Status ────────────────────────────────────────────────────────────────────
ps: ## Show container status
	$(COMPOSE) ps

health: ## Check API health endpoint
	@curl -s http://localhost:3001/health | python3 -m json.tool

# ── Shells ────────────────────────────────────────────────────────────────────
shell-api: ## Open a shell inside the API container
	$(COMPOSE) exec $(API_SVC) sh

shell-db: ## Open a psql shell
	$(COMPOSE) exec postgres psql -U flashinfo_admin -d flashinfo

shell-redis: ## Open a redis-cli shell
	$(COMPOSE) exec redis redis-cli -a flashinfo_redis_local

# ── Database ──────────────────────────────────────────────────────────────────
migrate: ## Run schema migrations (re-applies schema.sql)
	$(COMPOSE) exec postgres psql -U flashinfo_admin -d flashinfo -f /docker-entrypoint-initdb.d/01-schema.sql

seed: ## Re-run seed data
	$(COMPOSE) exec postgres psql -U flashinfo_admin -d flashinfo -f /docker-entrypoint-initdb.d/02-seed.sql

db-dump: ## Dump local DB to file
	$(COMPOSE) exec postgres pg_dump -U flashinfo_admin flashinfo > backups/local-$(shell date +%Y%m%d-%H%M%S).sql
	@echo "Dump saved to backups/"

# ── Testing ───────────────────────────────────────────────────────────────────
test: ## Run API tests
	$(COMPOSE) exec $(API_SVC) npm test

test-watch: ## Run API tests in watch mode
	$(COMPOSE) exec $(API_SVC) npm run test:watch

lint: ## Run linter
	$(COMPOSE) exec $(API_SVC) npm run lint

# ── LocalStack helpers ────────────────────────────────────────────────────────
ls-buckets: ## List LocalStack S3 buckets
	aws --endpoint-url=http://localhost:4566 s3 ls

ls-queues: ## List LocalStack SQS queues
	aws --endpoint-url=http://localhost:4566 sqs list-queues

ls-secrets: ## List LocalStack secrets
	aws --endpoint-url=http://localhost:4566 secretsmanager list-secrets

# ── Cleanup ───────────────────────────────────────────────────────────────────
clean: down ## Stop containers and remove images
	$(COMPOSE) down --rmi local

reset: down-volumes ## Full reset — delete all data and rebuild from scratch
	$(COMPOSE) build --no-cache
	$(MAKE) up

# ── Terraform helpers ────────────────────────────────────────────────────────
tf-bootstrap-backend: ## Create/update Terraform S3+DynamoDB backend resources
	@chmod +x scripts/bootstrap-terraform-backend.sh
	@./scripts/bootstrap-terraform-backend.sh

local-db-init: ## Initialize local PostgreSQL schema + seed (non-Docker)
	@chmod +x scripts/init-local-db.sh
	@./scripts/init-local-db.sh

local-up: ## Run backend + frontend without Docker on localhost:3001
	@chmod +x scripts/run-local-no-docker.sh
	@./scripts/run-local-no-docker.sh
