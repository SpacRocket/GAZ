.DEFAULT_GOAL := help
SHELL := /bin/bash

# Every recipe sources env.sh, so there is exactly one definition of where
# things live. Override any GAZ_* var on the command line or in env.local.sh:
#   make start GAZ_HDB=/fsx/hdb
E := set -a && . ./env.sh &&

# -noredirect keeps the results on stdout; leaving -debug OFF is what makes
# runtests.q exit with the failure count, which is what CI grades on.
TORQ_TEST = $$QCMD $$TORQHOME/torq.q -procfile $$TORQPROCESSES \
            -load $$GAZ_TESTS/helpers.q -noredirect

.PHONY: help bootstrap start stop restart status tail test test-unit \
        test-integration backfill backfill-marks backfill-all repl clean clean-data

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk -F':.*?## ' '{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

bootstrap: ## Fetch TorQ and create the data directories
	git submodule update --init --recursive
	@$(E) echo "QHOME=$$QHOME"; \
	  command -v q >/dev/null || { echo "q not on PATH — set QHOME in env.local.sh" >&2; exit 1; }; \
	  echo "data dirs under $$(dirname $$GAZ_HDB)"

start: ## Start the stack (make start P=rdb1 for one process)
	@$(E) bin/gaz start $${P:-all}

stop: ## Stop the stack
	@$(E) bin/gaz stop $${P:-all}

restart: ## Restart the stack
	@$(E) bin/gaz restart $${P:-all}

status: ## Show what is running
	@$(E) bin/gaz status

tail: ## Follow a process log: make tail P=rdb1
	@$(E) bin/gaz tail $${P:-stp1}

test: test-unit ## Run the unit suite (alias)

test-unit: ## Run unit tests — no running stack required
	@$(E) $(TORQ_TEST) -proctype test -procname test1 -test $$GAZ_TESTS/unit

# Runs against the DOCKER stack, not a local one. The feed handlers are Python
# and need PyKX, which is installed in the image but not on a dev machine — so
# a local stack has no data source and every "reaches the rdb" assertion would
# fail for want of a feed rather than for a real reason. Docker is also the
# shape that actually ships.
test-integration: ## Start the docker stack, run integration tests inside it
	@set -a && . ./env.sh && \
	  KX_B64_LIC=$$(base64 < $${QLIC:-$$HOME/Applications/q}/kc.lic | tr -d '\n') \
	  docker compose -f docker/docker-compose.yml up -d && \
	  echo "waiting for the stack..." && sleep 45 && \
	  docker compose -f docker/docker-compose.yml exec -T rdb \
	    bash -lc 'set -a && . /app/env.sh && $$QCMD $$TORQHOME/torq.q \
	      -procfile $$TORQPROCESSES -proctype itest -procname itest1 \
	      -load $$GAZ_TESTS/helpers.q -test $$GAZ_TESTS/integration -noredirect'

# Same reasoning as test-integration: the loader is Python and needs PyKX,
# which lives in the image and not on a dev machine. It runs inside the stp
# container because that is where the tickerplant it publishes to is, and where
# the state volume holding its ledger is mounted.
#
# Both dates are inclusive. The loader clamps the end short of whatever the
# live feed is already polling, so overlapping ranges are safe to ask for.
backfill: ## Backfill ENTSO-E power history: make backfill FROM=2026-01-01 TO=2026-06-30
	@[ -n "$(FROM)" ] && [ -n "$(TO)" ] || { \
	  echo "usage: make backfill FROM=YYYY-MM-DD TO=YYYY-MM-DD [ARGS=--dry-run]" >&2; \
	  exit 2; }
	@set -a && . ./env.sh && \
	  docker compose -f docker/docker-compose.yml exec -T stp \
	    python3 /app/code/tick/backfill_power.py $(FROM) $(TO) $(ARGS)

# Runs in the SORT container, not the stp: this one writes partitions straight
# into GAZ_HDB rather than publishing, and sort is the process the layout
# already designates as the writer against that mount (infra/README.md rule 1).
# Reload targets are hdb1/hdb2 at KDBBASEPORT+3/+4 per docker/process.csv —
# rule 3, they hold mmaps and will not see new partitions otherwise.
backfill-marks: ## Generate gas+carbon history into the HDB: make backfill-marks FROM=2026-08-07 TO=2026-09-05
	@[ -n "$(FROM)" ] && [ -n "$(TO)" ] || { \
	  echo "usage: make backfill-marks FROM=YYYY-MM-DD TO=YYYY-MM-DD [ARGS=--dry-run]" >&2; \
	  exit 2; }
	@set -a && . ./env.sh && \
	  docker compose -f docker/docker-compose.yml exec -T \
	    -e GAZ_RELOAD_TARGETS="hdb1:$$((KDBBASEPORT+3)),hdb2:$$((KDBBASEPORT+4))" \
	    sort python3 /app/code/tick/backfill_marks.py $(FROM) $(TO) $(ARGS)

# Both loaders over one range. They are not interchangeable — power goes through
# the tickerplant because `delivery` survives the STP's own `time` stamp, gas
# and carbon cannot because `time` is their only axis. See either script's
# docstring. Power needs an EOD afterwards to reach disk; marks are already there.
backfill-all: ## Power + marks over one range: make backfill-all FROM=2026-08-07 TO=2026-09-05
	@$(MAKE) backfill FROM=$(FROM) TO=$(TO) ARGS="$(ARGS)"
	@$(MAKE) backfill-marks FROM=$(FROM) TO=$(TO) ARGS="$(ARGS)"

repl: ## Interactive q as a TorQ process, connected to the running stack
	@$(E) bin/gaz repl itest1

repl-isolated: ## Interactive q with no stack needed (discovery off)
	@$(E) rlwrap -A $$QCMD $$TORQHOME/torq.q -proctype test -procname test1 \
	  -procfile $$TORQPROCESSES -load $$GAZ_TESTS/helpers.q -debug

clean: stop ## Stop everything and remove logs
	@$(E) rm -rf $$KDBLOG/*.log

clean-data: stop ## Also delete the local hdb, wdb and tickerplant logs
	@$(E) rm -rf $$GAZ_HDB/* $$GAZ_WDB/* $$GAZ_TPLOG/*
	@echo "local data wiped"
