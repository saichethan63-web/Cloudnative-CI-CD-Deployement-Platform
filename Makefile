.PHONY: help up down logs test lint build load tf-init tf-plan tf-apply tf-destroy gh-config

help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-12s %s\n", $$1, $$2}'

.env:
	cp .env.example .env

up: .env ## Build and start the whole stack locally (http://localhost:8080)
	docker compose up -d --build

down: ## Stop the stack (add -v manually to delete data volumes)
	docker compose down

logs: ## Tail all logs
	docker compose logs -f --tail=50

test: ## Run unit tests
	cd app && npm ci && npm test

lint: ## Lint the app
	cd app && npm ci && npm run lint

load: ## Generate traffic against the local stack
	scripts/load-test.sh http://localhost:8080 60

tf-init: ## terraform init
	cd terraform && terraform init

tf-plan: ## terraform plan
	cd terraform && terraform plan

tf-apply: ## terraform apply
	cd terraform && terraform apply

tf-destroy: ## Tear down all AWS resources
	cd terraform && terraform destroy

gh-config: ## Push Terraform outputs into GitHub variables/secrets
	scripts/set-github-config.sh
