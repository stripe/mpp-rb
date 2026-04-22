.PHONY: test lint format typecheck ci

test:
	bundle exec rake test

lint:
	bundle exec standardrb

format:
	bundle exec standardrb --fix

typecheck:
	bundle exec srb tc

ci: lint typecheck test
