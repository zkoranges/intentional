SHELL := /bin/bash

FOUNDRY_PROFILE ?= ci
FUZZ_SEED := 0x5245534552564f4952
AAVE_FORK_TEST := test/fork/AaveStataUSDC.t.sol

.PHONY: build fmt test test-unit test-integration test-invariants test-fork demo demo-aave

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
	forge test --match-path "$(AAVE_FORK_TEST)" --fork-url "$(ETH_RPC_URL)"

demo:
	forge script script/Demo.s.sol:Demo -vv

demo-aave:
	@test -n "$(ETH_RPC_URL)" || (echo "ETH_RPC_URL is required" && exit 1)
	forge test --match-path "$(AAVE_FORK_TEST)" --fork-url "$(ETH_RPC_URL)" -vv

