.PHONY: help all setup deps build fmt fmt-check lint test coverage ci dialyzer e2e

MIX ?= mix
ELIXIR ?= elixir

help:
	@echo "Targets: setup, deps, fmt, fmt-check, lint, test, coverage, dialyzer, e2e, ci"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

build:
	$(MIX) build

fmt:
	$(MIX) format

fmt-check:
	$(MIX) format --check-formatted

lint:
	$(MIX) lint

coverage:
	$(MIX) test --cover --max-cases 1
	SYMPHONY_ATTEMPT_FUSE_COVERAGE=1 $(MIX) test --cover test/symphony_elixir/attempt_fuse_test.exs test/symphony_elixir/github_attempt_ledger_test.exs test/symphony_elixir/instance_lock_test.exs test/symphony_elixir/github_adapter_test.exs test/symphony_elixir/orchestrator_attempt_fuse_test.exs
	$(ELIXIR) scripts/check_attempt_fuse_coverage.exs

test:
	$(MIX) test

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format short

e2e:
	SYMPHONY_RUN_LIVE_E2E=1 $(MIX) test test/symphony_elixir/live_e2e_test.exs

ci:
	$(MAKE) setup
	$(MAKE) build
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) coverage
	$(MAKE) dialyzer

all: ci
