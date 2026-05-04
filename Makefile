.PHONY: test test-integration node node-stop lint format typecheck ci

test:
	bundle exec rake test

test-integration:
	TEMPO_RPC_URL=$${TEMPO_RPC_URL:-http://localhost:8545} bundle exec rake test:integration

node:
	docker compose up -d --wait

node-stop:
	docker compose down

lint:
	bundle exec standardrb

format:
	bundle exec standardrb --fix

typecheck:
	bundle exec srb tc

ci: lint typecheck test
