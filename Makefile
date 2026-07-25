SHELL := /bin/bash

FOUNDRY_PROFILE ?= ci
FUZZ_SEED := 0x5245534552564f4952
AAVE_FORK_TEST := test/fork/AaveStataUSDC.t.sol
LIDO_V2_FORK_TEST := test/fork/LidoWithdrawalClaim.t.sol
AQUA_INTENT_FORK_TEST := test/fork/AquaIntentWstETH.t.sol

.PHONY: build fmt test test-unit test-integration test-invariants test-fork demo demo-aave demo-aqua-intent demo-v2 jury-demo jury-ui demo-lido-v2 live-product-e2e rehearse-live-activation preflight-mainnet-v2 verify-live-v2

build:
	forge build

fmt:
	forge fmt --check

test:
	FOUNDRY_PROFILE=$(FOUNDRY_PROFILE) forge test \
		--no-match-path "test/fork/*" \
		--fuzz-seed $(FUZZ_SEED)

test-unit:
	FOUNDRY_PROFILE=$(FOUNDRY_PROFILE) forge test \
		--match-path "test/unit/*" \
		--fuzz-seed $(FUZZ_SEED)

test-integration:
	FOUNDRY_PROFILE=$(FOUNDRY_PROFILE) forge test \
		--match-path "test/integration/*" \
		--fuzz-seed $(FUZZ_SEED)

test-invariants:
	FOUNDRY_PROFILE=$(FOUNDRY_PROFILE) forge test \
		--match-path "test/invariants/*" \
		--fuzz-seed $(FUZZ_SEED)

test-fork:
	@test -n "$(ETH_RPC_URL)" || (echo "ETH_RPC_URL is required" && exit 1)
	@test -s test/fork/fixtures/uniswap-route.json || (echo "fixture missing: run \`node frontend/scripts/fetch-uniswap-route.mjs\`" && exit 1)
	@test -s test/fork/fixtures/uniswap-payout-route.json || (echo "fixture missing: run \`MODE=payout node frontend/scripts/fetch-uniswap-route.mjs\`" && exit 1)
	@forge test --match-path "test/fork/*" --fork-url "$(ETH_RPC_URL)"

demo:
	@output="$$(forge script script/Demo.s.sol:Demo -vv 2>&1)" || { \
		printf '%s\n' "$$output"; \
		exit 1; \
	}; \
	printf '%s\n' "$$output" | sed -n '/== Logs ==/,$$ { /^  /s/^  //p; }'

demo-aave:
	@test -n "$(ETH_RPC_URL)" || (echo "ETH_RPC_URL is required" && exit 1)
	forge test --match-path "$(AAVE_FORK_TEST)" --fork-url "$(ETH_RPC_URL)" -vv

demo-aqua-intent:
	@test -n "$(ETH_RPC_URL)" || (echo "ETH_RPC_URL is required for the current-mainnet Aqua intent proof" && exit 1)
	@output="$$(AQUA_INTENT_CURRENT_MAINNET=1 forge test \
		--match-path "$(AQUA_INTENT_FORK_TEST)" \
		--match-test "test_ProductionAquaIntentQuotesAndFillsWstETHForWETH" \
		--fork-url "$(ETH_RPC_URL)" -vv 2>&1)" || { \
		printf '%s\n' "$$output" | perl -pe 's#https?://[^[:space:]]+#<RPC_URL>#g'; \
		exit 1; \
	}; \
	printf '%s\n' "$$output" | sed -n '/\[PASS\].*test_ProductionAquaIntent/,/Suite result:/p'

demo-v2:
	@output="$$(forge script script/V2Demo.s.sol:V2Demo -vv 2>&1)" || { \
		printf '%s\n' "$$output"; \
		exit 1; \
	}; \
	printf '%s\n' "$$output" | sed -n '/== Logs ==/,$$ { /^  /s/^  //p; }'

jury-demo:
	@test -n "$(ETH_RPC_URL)" || (echo "ETH_RPC_URL is required for the pinned Reservoir v2 Lido demo" && exit 1)
	@output="$$(forge test \
		--match-path "$(LIDO_V2_FORK_TEST)" \
		--match-test "test_JuryDemo_RealLidoClaimBeforeRealAavePayment" \
		--fork-url "$(ETH_RPC_URL)" -vv 2>&1)" || { \
		printf '%s\n' "$$output"; \
		exit 1; \
	}; \
	printf '%s\n' "$$output" | sed -n '/\[PASS\].*test_JuryDemo/,/Suite result:/p'

demo-lido-v2: jury-demo

live-product-e2e:
	@test -n "$(ETH_RPC_URL)" || (echo "ETH_RPC_URL is required for the chain-1 production rehearsal" && exit 1)
	./scripts/run-live-product-e2e.sh

jury-ui:
	@test -n "$(ETH_RPC_URL)" || (echo "ETH_RPC_URL is required for the chain-1 browser demo" && exit 1)
	JURY_BROWSER_MODE=1 ./scripts/run-live-product-e2e.sh

rehearse-live-activation:
	@test -n "$(ETH_RPC_URL)" || (echo "ETH_RPC_URL is required for the current-head activation rehearsal" && exit 1)
	./scripts/rehearse-live-activation.sh

preflight-mainnet-v2:
	./scripts/preflight-mainnet-v2.sh

verify-live-v2:
	npm --prefix frontend run verify:deployment

docs:
	@echo "Reservoir docs → http://localhost:3000"
	@cd docs-site && python3 -m http.server 3000
