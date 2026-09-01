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
        test-integration repl clean clean-data

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
