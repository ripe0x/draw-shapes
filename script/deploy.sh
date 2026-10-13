#!/usr/bin/env bash
# The one deploy wrapper: script/deploy.sh <anvil|sepolia|mainnet>
# Sources script/env/<env>.env, which carries the build profile that selects the ladder, evaluates
# guards, warms the build, broadcasts one transaction at a time, fills in the record
# (deployments/<chainId>.json; on anvil DEPLOYMENT_RECORD or the port-scoped file), and reads back
# the result. DRY_RUN=1 evaluates every
# guard and simulates without a wallet, broadcast or verification; only the git branch/clean-tree
# guards downgrade to a warning under DRY_RUN. All other guards refuse. Secrets never enter
# env files or argv: the keystore is selected by account name; ETHERSCAN_API_KEY and
# KEYSTORE_PASSWORD_FILE come from the shell only.
set -euo pipefail
cd "$(dirname "$0")/.."

ENV_NAME="${1:-}"
[[ -n "$ENV_NAME" ]] || { echo "usage: script/deploy.sh <anvil|sepolia|mainnet>"; exit 1; }
ENV_FILE="script/env/${ENV_NAME}.env"
[[ -f "$ENV_FILE" ]] || { echo "no env file: $ENV_FILE"; exit 1; }
# Empty assignments in the env file do not override values already in the shell.
# CREATE_POOL set in the shell takes precedence over the env file. Launch funding is always a
# separate post-window Seed transaction.
CREATE_POOL_ARG="${CREATE_POOL:-}"
# The owner-rehearsal wrapper deliberately supplies the production 24-hour delay. Preserve that
# explicit input across the nonempty one-hour default in anvil.env; chain guards still reject any
# unsupported value on mainnet, Sepolia or local.
OPEN_DELAY_SECONDS_ARG="${OPEN_DELAY_SECONDS:-}"
set -a; source <(grep -vE '^[A-Za-z_][A-Za-z0-9_]*=$' "$ENV_FILE"); set +a
CREATE_POOL="${CREATE_POOL_ARG:-${CREATE_POOL:-0}}"
OPEN_DELAY_SECONDS="${OPEN_DELAY_SECONDS_ARG:-${OPEN_DELAY_SECONDS:-}}"
DRY_RUN="${DRY_RUN:-0}"
RPC_URL="${RPC_URL:-${RPC_URL_DEFAULT:-}}"

refuse() { echo "guard failed: $*"; exit 1; }
warn_or_refuse() {
  echo "guard failed: $*"
  if [[ "$DRY_RUN" == "1" ]]; then echo "(DRY_RUN: continuing)"; else exit 1; fi
}

# Required values. A dry run also refuses an undecided environment such as mainnet.env before its
# role addresses are filled in.
for v in CHAIN_ID RPC_URL DEPLOYER ADMIN REVENUE_RECIPIENT RETIREMENT_BENEFICIARY SHAPES FWA_FACTORY FWA_IMPLEMENTATION OPEN_DELAY_SECONDS \
         KEEPER_BUDGET_GAS_PRICE_WEI WITHDRAWAL_MAX_WAIT_SECONDS; do
  [[ -n "${!v:-}" ]] || refuse "$v is empty in $ENV_FILE"
done
case "$ENV_NAME" in
  anvil) EXPECTED_CHAIN_ID=31337 ;;
  sepolia) EXPECTED_CHAIN_ID=11155111 ;;
  mainnet) EXPECTED_CHAIN_ID=1 ;;
  *) refuse "unsupported environment $ENV_NAME" ;;
esac
[[ "$CHAIN_ID" == "$EXPECTED_CHAIN_ID" ]] || refuse "$ENV_NAME must use chain id $EXPECTED_CHAIN_ID"
if [[ "$ENV_NAME" == "anvil" ]]; then
  source script/local-config.sh
  shapes_validate_local_rpc_url "$RPC_URL" || refuse "unsafe local RPC_URL"
  LOCAL_RPC_PORT=$(shapes_local_rpc_port "$RPC_URL")
  if [[ "$LOCAL_RPC_PORT" == "$SHAPES_OWNER_REHEARSAL_PORT" ]]; then
    ANVIL_PID_FILE=".anvil$(shapes_local_suffix "$LOCAL_RPC_PORT").pid"
    if ! shapes_require_scoped_anvil_owner "$LOCAL_RPC_PORT" "$ANVIL_PID_FILE"; then
      refuse "owner-rehearsal port is not owned by the exact scoped Anvil PID"
    fi
  fi
fi

[[ "$CREATE_POOL" == "0" || "$CREATE_POOL" == "1" ]] || refuse "CREATE_POOL must be 0 or 1"
if [[ "$CREATE_POOL" == "1" ]]; then
  [[ "$ENV_NAME" == "anvil" ]] || refuse "CREATE_POOL=1 is only supported on anvil; a live chain creates its pool from the admin wallet through createFwaPool"
  [[ -n "${POOL_SALT:-}" ]] || refuse "POOL_SALT is empty"
  [[ -n "${EXPECTED_CREATION_FEE:-}" ]] || refuse "EXPECTED_CREATION_FEE is empty"
  [[ "${DEPLOYER,,}" == "${ADMIN,,}" ]] || refuse "DEPLOYER must equal ADMIN when CREATE_POOL=1"
fi
# The controller stores this table at deployment, so reject malformed or stale launch settings
# before any build or broadcast. Seed.s.sol reads this immutable deployed table later.
script/validate-seed-config.sh

case "${WALLET_MODE:-keystore}" in
  anvil) : ;;
  keystore) [[ -n "${KEYSTORE_ACCOUNT:-}" ]] || refuse "KEYSTORE_ACCOUNT is empty" ;;
  *) refuse "unknown WALLET_MODE ${WALLET_MODE:-}" ;;
esac

# Chain identity, when the RPC is reachable.
RPC_REACHABLE=0
if LIVE_CHAIN=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null); then
  RPC_REACHABLE=1
  [[ "$LIVE_CHAIN" == "$CHAIN_ID" ]] || refuse "RPC chain id $LIVE_CHAIN != $CHAIN_ID"
elif [[ "$DRY_RUN" != "1" ]]; then
  refuse "cannot reach RPC $RPC_URL"
fi

# Refuse missing or incompatible dependencies before a broadcast. The creation checks also catch
# mutable factory gates and fee drift before deploying a custody that cannot create its pool.
if [[ "$RPC_REACHABLE" == "1" ]]; then
  if [[ "$ENV_NAME" == "anvil" && "$DRY_RUN" != "1" ]]; then
    for v in LOCAL_TEST_WALLET_1 LOCAL_TEST_WALLET_2 LOCAL_TEST_BALANCE_WEI; do
      [[ -n "${!v:-}" ]] || refuse "$v is empty in $ENV_FILE"
    done
    LOCAL_TEST_BALANCE_HEX=$(cast --to-hex "$LOCAL_TEST_BALANCE_WEI")
    for wallet in "$LOCAL_TEST_WALLET_1" "$LOCAL_TEST_WALLET_2"; do
      cast rpc --rpc-url "$RPC_URL" anvil_setBalance "$wallet" "$LOCAL_TEST_BALANCE_HEX" >/dev/null
    done
    echo "local test wallets funded with $(cast from-wei "$LOCAL_TEST_BALANCE_WEI" ether) ETH"
  fi

  for entry in "SHAPES:$SHAPES" "FWA_FACTORY:$FWA_FACTORY"; do
    LABEL="${entry%%:*}"
    ADDRESS="${entry#*:}"
    CODE=$(cast code --rpc-url "$RPC_URL" "$ADDRESS" 2>/dev/null || echo "0x")
    [[ "$CODE" != "0x" ]] || refuse "$LABEL has no code on chain $CHAIN_ID"
  done
  if [[ -n "${FWA_IMPLEMENTATION:-}" ]]; then
    LIVE_IMPLEMENTATION=$(cast call --rpc-url "$RPC_URL" "$FWA_FACTORY" 'implementation()(address)' 2>/dev/null) \
      || refuse "FWA_FACTORY does not expose implementation()"
    [[ "${LIVE_IMPLEMENTATION,,}" == "${FWA_IMPLEMENTATION,,}" ]] \
      || refuse "FWA factory implementation $LIVE_IMPLEMENTATION != $FWA_IMPLEMENTATION"
  fi
  if [[ -n "${FWA_VRF_SERVICE:-}" ]]; then
    LIVE_VRF_SERVICE=$(cast call --rpc-url "$RPC_URL" "$FWA_FACTORY" 'vrfService()(address)' 2>/dev/null) \
      || refuse "FWA_FACTORY does not expose vrfService()"
    [[ "${LIVE_VRF_SERVICE,,}" == "${FWA_VRF_SERVICE,,}" ]] \
      || refuse "FWA factory VRF service $LIVE_VRF_SERVICE != $FWA_VRF_SERVICE"
  fi
  if [[ "$CREATE_POOL" == "1" ]]; then
    FACTORY_ENABLED=$(cast call --rpc-url "$RPC_URL" "$FWA_FACTORY" 'poolCreationEnabled()(bool)' 2>/dev/null) \
      || refuse "FWA_FACTORY does not expose poolCreationEnabled()"
    [[ "$FACTORY_ENABLED" == "true" ]] || refuse "FWA factory pool creation is disabled"
    FACTORY_FEE=$(cast call --rpc-url "$RPC_URL" "$FWA_FACTORY" 'poolCreationFee()(uint256)' 2>/dev/null | awk '{print $1}') \
      || refuse "FWA_FACTORY does not expose poolCreationFee()"
    [[ "$FACTORY_FEE" == "$EXPECTED_CREATION_FEE" ]] \
      || refuse "FWA factory creation fee $FACTORY_FEE != EXPECTED_CREATION_FEE $EXPECTED_CREATION_FEE"
    REMAINING_ALLOWANCE=$(cast call --rpc-url "$RPC_URL" "$FWA_FACTORY" 'remainingPoolAllowance(address)(uint256)' "$ADMIN" 2>/dev/null | awk '{print $1}') \
      || refuse "FWA_FACTORY does not expose remainingPoolAllowance(address)"
    [[ "$REMAINING_ALLOWANCE" != "0" ]] || refuse "ADMIN has no remaining FWA pool allowance"
  fi
fi

# Git guards (warn only under DRY_RUN).
if [[ "${REQUIRE_MAIN_BRANCH:-0}" == "1" ]]; then
  BRANCH=$(git branch --show-current)
  [[ "$BRANCH" == "main" ]] || warn_or_refuse "not on main (on $BRANCH)"
  [[ -z "$(git status --porcelain)" ]] || warn_or_refuse "working tree not clean"
fi

# Secret-file guard before any broadcast.
if git ls-files --error-unmatch .env >/dev/null 2>&1; then refuse ".env is tracked"; fi

DEPLOY_ARGS=()
if [[ "$DRY_RUN" != "1" ]]; then
  # Delegated deployer guard: a 7702-delegated signer needs --slow (always used here) and no
  # gapped nonces.
  CODE=$(cast code --rpc-url "$RPC_URL" "$DEPLOYER" 2>/dev/null || echo "0x")
  if [[ "$CODE" == 0xef0100* ]]; then
    echo "note: deployer carries an EIP-7702 delegation; broadcasting with --slow"
  fi

  case "${WALLET_MODE:-keystore}" in
    anvil) DEPLOY_ARGS=(--unlocked --sender "$DEPLOYER") ;;
    keystore)
      # KEYSTORE_PASSWORD_FILE (shell only, never in an env file) unlocks without a prompt; the
      # password never appears in argv or in any file of this repository.
      if [[ -n "${KEYSTORE_PASSWORD_FILE:-}" ]]; then
        DEPLOY_ARGS=(--account "$KEYSTORE_ACCOUNT" --password-file "$KEYSTORE_PASSWORD_FILE" --sender "$DEPLOYER")
      else
        DEPLOY_ARGS=(--account "$KEYSTORE_ACCOUNT" --sender "$DEPLOYER")
      fi ;;
  esac
fi

VERIFY_ARGS=()
if [[ "${VERIFY:-0}" == "1" && "$DRY_RUN" != "1" ]]; then
  [[ -n "${ETHERSCAN_API_KEY:-}" ]] || refuse "ETHERSCAN_API_KEY not in the shell environment"
  VERIFY_ARGS=(--verify)
fi

# Warm the deploy sources before any broadcast.
forge build --skip test

# Sepolia-profile library size gate: forge build --sizes lists contracts only, so a linked
# library over the EIP-170 runtime limit is invisible to it and only surfaces at the broadcast's
# own size prompt. Refuse here instead, before that prompt.
if [[ "$ENV_NAME" == "sepolia" ]]; then
  FOUNDRY_PROFILE=sepolia forge test --match-path test/unit/CodeSize.t.sol     || refuse "a linked library or deployed contract exceeds the EIP-170 size limit under the sepolia profile"
fi

export CREATE_POOL
export POOL_SALT="${POOL_SALT:-0}"
export EXPECTED_CREATION_FEE="${EXPECTED_CREATION_FEE:-0}"
export GIT_COMMIT
GIT_COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"

# Record location, one rule for every run: an anvil run uses DEPLOYMENT_RECORD or the port-scoped
# file, a live chain uses deployments/<chainId>.json. Deploy.s.sol writes the record at this path
# itself, so concurrent local deploys on different ports never touch each other's record.
if [[ "$ENV_NAME" == "anvil" ]]; then
  RECORD="${DEPLOYMENT_RECORD:-deployments/${CHAIN_ID}-${LOCAL_RPC_PORT}.json}"
else
  RECORD="deployments/${CHAIN_ID}.json"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  # A dry run writes its would-be record to a scratch path, removed on exit, so the record at
  # $RECORD stays as it was.
  DRY_RECORD="deployments/.dry-run-${CHAIN_ID}-$$.json"
  trap 'rm -f "$DRY_RECORD"' EXIT
  export DEPLOYMENT_RECORD="$DRY_RECORD"
  echo "DRY_RUN: simulating Deploy for chain $CHAIN_ID as $DEPLOYER; a broadcast writes the record to $RECORD"
  forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --sender "$DEPLOYER" --skip test -vvv
  echo "DRY_RUN: would-be record for chain $CHAIN_ID (scratch copy of $RECORD):"
  cat "$DRY_RECORD" 2>/dev/null || echo "(Deploy.s.sol wrote no record this run)"
  exit 0
fi

echo "Broadcasting Deploy to chain $CHAIN_ID from $DEPLOYER"
export DEPLOYMENT_RECORD="$RECORD"
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" "${DEPLOY_ARGS[@]}" --broadcast --slow --skip test "${VERIFY_ARGS[@]}" -vvv

# Concurrent local sessions on different ports but the same chain id (every anvil fork answers
# 31337) would otherwise race to write the same broadcast pointer file. A caller running more
# than one at once (script/fork-e2e.sh) sets FOUNDRY_BROADCAST to its own root so forge writes
# there instead; forge itself defaults FOUNDRY_BROADCAST to "broadcast" when unset, so a plain
# deploy is unaffected.
BROADCAST_FILE="${FOUNDRY_BROADCAST:-broadcast}/Deploy.s.sol/${CHAIN_ID}/run-latest.json"

# Fill the linked library addresses into the record from the broadcast transactions: forge deploys
# linked libraries as CREATE2 (deterministic address, deduped across runs); every CREATE or CREATE2
# transaction whose target is not one of the three deployed contracts is a library deploy.
source script/deployment-libraries.sh
shapes_record_libraries "$RECORD" "$BROADCAST_FILE"

CUSTODY=$(jq -r '.custody' "$RECORD")
CONTROLLER=$(jq -r '.controller' "$RECORD")
if [[ "$CREATE_POOL" == "1" ]]; then
  POOL_SALT_BYTES=$(cast abi-encode 'f(uint256)' "$POOL_SALT")
  cast send --rpc-url "$RPC_URL" --unlocked --from "$ADMIN" "$CUSTODY" \
    'createFwaPool(bytes32,uint256,address)(address)' "$POOL_SALT_BYTES" "$EXPECTED_CREATION_FEE" \
    "$FWA_IMPLEMENTATION" >/dev/null
  POOL=$(cast call --rpc-url "$RPC_URL" "$CUSTODY" 'fwaPool()(address)')
  OPEN_DEADLINE=$(cast call --rpc-url "$RPC_URL" "$CONTROLLER" 'openDeadline()(uint64)')
  [[ "$OPEN_DEADLINE" =~ ^[0-9]+$ && "$OPEN_DEADLINE" != "0" ]] || refuse "funding clock did not start"
  jq --arg pool "$POOL" --argjson deadline "$OPEN_DEADLINE" '.fwaPool = $pool | .openAt = $deadline' "$RECORD" > "$RECORD.tmp" && mv "$RECORD.tmp" "$RECORD"
  echo "FWA pool created at $POOL"
fi

echo "record: $RECORD"
POOL=$(jq -r '.fwaPool' "$RECORD")
echo "readback: state=$(cast call --rpc-url "$RPC_URL" "$CUSTODY" 'state()(uint8)') admin=$(cast call --rpc-url "$RPC_URL" "$CUSTODY" 'admin()(address)') operatorRecipient=$(cast call --rpc-url "$RPC_URL" "$CUSTODY" 'operatorRecipient()(address)')"
echo "readback: controller=$(cast call --rpc-url "$RPC_URL" "$CUSTODY" 'controller()(address)') openAt=$(cast call --rpc-url "$RPC_URL" "$CONTROLLER" 'openAt()(uint64)')"
if [[ "$POOL" != "0x0000000000000000000000000000000000000000" ]]; then
  echo "readback: fwaPool owner=$(cast call --rpc-url "$RPC_URL" "$POOL" 'owner()(address)')"
fi
echo "custody: https://evm.now/address/${CUSTODY}?chainId=${CHAIN_ID}"
echo "controller: https://evm.now/address/${CONTROLLER}?chainId=${CHAIN_ID}"
if [[ "$POOL" != "0x0000000000000000000000000000000000000000" ]]; then
  echo "fwaPool: https://evm.now/address/${POOL}?chainId=${CHAIN_ID}"
fi
