#!/usr/bin/env bash
# The one deploy wrapper: script/deploy.sh <anvil|sepolia|mainnet>
# Sources script/env/<env>.env, evaluates guards, warms the build, broadcasts one transaction at a
# time, writes the record (deployments/<chainId>.json; on anvil deployments/<chainId>-<port>.json)
# and reads back the result. DRY_RUN=1 evaluates every guard and simulates without a wallet,
# broadcast or verification; only the git branch/clean-tree guards downgrade to a warning under
# DRY_RUN. All other guards refuse. Secrets never enter env files or argv: the keystore is selected
# by account name; ETHERSCAN_API_KEY and KEYSTORE_PASSWORD_FILE come from the shell only.
set -euo pipefail
cd "$(dirname "$0")/.."

ENV_NAME="${1:-}"
[[ -n "$ENV_NAME" ]] || { echo "usage: script/deploy.sh <anvil|sepolia|mainnet>"; exit 1; }
ENV_FILE="script/env/${ENV_NAME}.env"
[[ -f "$ENV_FILE" ]] || { echo "no env file: $ENV_FILE"; exit 1; }
# Empty assignments in the env file do not override values already in the shell. CREATE_POOL set
# in the shell takes precedence over the env file.
CREATE_POOL_ARG="${CREATE_POOL:-}"
set -a; source <(grep -vE '^[A-Za-z_][A-Za-z0-9_]*=$' "$ENV_FILE"); set +a
CREATE_POOL="${CREATE_POOL_ARG:-${CREATE_POOL:-0}}"
DRY_RUN="${DRY_RUN:-0}"
RPC_URL="${RPC_URL:-${RPC_URL_DEFAULT:-}}"

refuse() { echo "guard failed: $*"; exit 1; }
warn_or_refuse() {
  echo "guard failed: $*"
  if [[ "$DRY_RUN" == "1" ]]; then echo "(DRY_RUN: continuing)"; else exit 1; fi
}

# Required values. A dry run also refuses an undecided environment such as mainnet.env before its
# values are filled in.
REQUIRED=(CHAIN_ID RPC_URL DEPLOYER ADMIN SHAPES FWA_FACTORY FWA_IMPLEMENTATION MIX_ROWS LADDER
  PREMIUM_BPS MAINTENANCE_BPS FEED_BPS MINOR_SHARE_BPS
  ENTRY_FLOOR_BPS ENTRY_CAP_BPS ENTRY_PAYBACK_DAYS
  GRAIL_MINOR_TARGET_WEI GRAIL_MINOR_STEP_WEI GRAIL_MINOR_LIST_BPS GRAIL_MINOR_DECAY_WEI_PER_PULL GRAIL_MINOR_FLOOR_WEI
  GRAIL_MAJOR_TARGET_WEI GRAIL_MAJOR_STEP_WEI GRAIL_MAJOR_LIST_BPS GRAIL_MAJOR_DECAY_WEI_PER_PULL GRAIL_MAJOR_FLOOR_WEI
  NAV_CAP_FLOOR_WEI TURNOVER_BPS FOUNDER_WINDOW_SECONDS ROTATE_INTERVAL_SECONDS OPENING_DEADLINE_SECONDS MIN_ITEMS
  GRAIL_PROB_CAP_BPS BATCH_MIN BATCH_MAX_AGE_SECONDS SURPRISE_BPS RESTORE_K BAND_BPS RESERVE_BPS TIP_WEI)
[[ "$ENV_NAME" == "anvil" ]] || REQUIRED+=(DRAW_PACKS)
for v in "${REQUIRED[@]}"; do
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
  LOCAL_HOST=$(sed -E 's#^[a-z]+://([^:/]+).*#\1#' <<<"$RPC_URL")
  [[ "$LOCAL_HOST" == "127.0.0.1" || "$LOCAL_HOST" == "localhost" ]] || refuse "anvil RPC_URL host must be 127.0.0.1 or localhost"
  LOCAL_RPC_PORT=$(sed -nE 's#^[a-z]+://[^:/]+:([0-9]+).*#\1#p' <<<"$RPC_URL")
  [[ -n "$LOCAL_RPC_PORT" ]] || refuse "anvil RPC_URL needs an explicit port"
fi

[[ "$CREATE_POOL" == "0" || "$CREATE_POOL" == "1" ]] || refuse "CREATE_POOL must be 0 or 1"
if [[ "$CREATE_POOL" == "1" ]]; then
  [[ "$ENV_NAME" == "anvil" ]] || refuse "CREATE_POOL=1 is only supported on anvil; a live chain creates its pool from the admin wallet through createFwaPool"
  [[ -n "${EXPECTED_CREATION_FEE:-}" ]] || refuse "EXPECTED_CREATION_FEE is empty"
  [[ "${DEPLOYER,,}" == "${ADMIN,,}" ]] || refuse "DEPLOYER must equal ADMIN when CREATE_POOL=1"
fi

case "${WALLET_MODE:-keystore}" in
  anvil) [[ "$ENV_NAME" == "anvil" ]] || refuse "WALLET_MODE=anvil is only valid for the anvil environment" ;;
  keystore) [[ "$DRY_RUN" == "1" || -n "${KEYSTORE_ACCOUNT:-}" ]] || refuse "KEYSTORE_ACCOUNT is empty" ;;
  *) refuse "unknown WALLET_MODE ${WALLET_MODE:-}" ;;
esac

# The build must carry the ladder the environment expects (Pool compiles Denominations.UNIT in).
forge config --json 2>/dev/null | jq -e --arg l "ladders/${LADDER}/" '.remappings | any(contains("ladder/=") and contains($l))' >/dev/null \
  || refuse "forge config does not remap ladder/ to lib/shapes/ladders/${LADDER} (profile ${FOUNDRY_PROFILE:-default})"

# Chain identity, when the RPC is reachable.
RPC_REACHABLE=0
if LIVE_CHAIN=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null); then
  RPC_REACHABLE=1
  [[ "$LIVE_CHAIN" == "$CHAIN_ID" ]] || refuse "RPC chain id $LIVE_CHAIN != $CHAIN_ID"
elif [[ "$DRY_RUN" != "1" ]]; then
  refuse "cannot reach RPC $RPC_URL"
fi

# Refuse missing or incompatible dependencies before a broadcast.
if [[ "$RPC_REACHABLE" == "1" ]]; then
  for entry in "SHAPES:$SHAPES" "FWA_FACTORY:$FWA_FACTORY" "DRAW_PACKS:${DRAW_PACKS:-}"; do
    LABEL="${entry%%:*}"
    ADDRESS="${entry#*:}"
    [[ -n "$ADDRESS" ]] || continue
    CODE=$(cast code --rpc-url "$RPC_URL" "$ADDRESS" 2>/dev/null || echo "0x")
    [[ "$CODE" != "0x" ]] || refuse "$LABEL has no code on chain $CHAIN_ID"
  done
  LIVE_IMPLEMENTATION=$(cast call --rpc-url "$RPC_URL" "$FWA_FACTORY" 'implementation()(address)' 2>/dev/null) \
    || refuse "FWA_FACTORY does not expose implementation()"
  [[ "${LIVE_IMPLEMENTATION,,}" == "${FWA_IMPLEMENTATION,,}" ]] \
    || refuse "FWA factory implementation $LIVE_IMPLEMENTATION != $FWA_IMPLEMENTATION"
  if [[ -n "${FWA_VRF_SERVICE:-}" ]]; then
    LIVE_VRF_SERVICE=$(cast call --rpc-url "$RPC_URL" "$FWA_FACTORY" 'vrfService()(address)' 2>/dev/null) \
      || refuse "FWA_FACTORY does not expose vrfService()"
    [[ "${LIVE_VRF_SERVICE,,}" == "${FWA_VRF_SERVICE,,}" ]] \
      || refuse "FWA factory VRF service $LIVE_VRF_SERVICE != $FWA_VRF_SERVICE"
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
  # A 7702-delegated signer allows one in-flight transaction; --slow (always used here) waits for
  # each receipt.
  CODE=$(cast code --rpc-url "$RPC_URL" "$DEPLOYER" 2>/dev/null || echo "0x")
  if [[ "$CODE" == 0xef0100* ]]; then
    echo "note: deployer carries an EIP-7702 delegation; broadcasting with --slow"
  fi

  case "${WALLET_MODE:-keystore}" in
    anvil) DEPLOY_ARGS=(--unlocked --sender "$DEPLOYER") ;;
    keystore)
      # KEYSTORE_PASSWORD_FILE (shell only, never in an env file) unlocks without a prompt.
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

# Warm the build before the broadcast.
forge build --skip test

# EIP-170: Pool, PoolAdmin, PoolListing and Lens runtime code must fit 24576 bytes. A local fork started with
# --disable-code-size-limit can set ANVIL_DISABLE_SIZE_LIMIT=1 to continue past this guard.
SIZE_ARGS=()
for c in Pool PoolAdmin PoolListing Lens; do
  SIZE=$(( ($(forge inspect "$c" deployedBytecode | wc -c) - 3) / 2 ))
  if (( SIZE > 24576 )); then
    if [[ "$ENV_NAME" == "anvil" && "${ANVIL_DISABLE_SIZE_LIMIT:-0}" == "1" ]]; then
      echo "warning: $c runtime is $SIZE bytes, over the EIP-170 limit; size limit disabled for this local run"
      SIZE_ARGS=(--disable-code-size-limit)
    else
      refuse "$c runtime is $SIZE bytes, over the EIP-170 limit of 24576"
    fi
  fi
done

export GIT_COMMIT
GIT_COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"

# Record location, one rule for every run: an anvil run uses deployments/<chainId>-<port>.json, a
# live chain uses deployments/<chainId>.json. Deploy.s.sol writes the record at this path itself,
# so concurrent local deploys on different ports never touch each other's record.
if [[ "$ENV_NAME" == "anvil" ]]; then
  RECORD="deployments/${CHAIN_ID}-${LOCAL_RPC_PORT}.json"
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
  forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --sender "$DEPLOYER" "${SIZE_ARGS[@]}" --skip test -v
  echo "DRY_RUN: would-be record for chain $CHAIN_ID (scratch copy of $RECORD):"
  cat "$DRY_RECORD" 2>/dev/null || echo "(Deploy.s.sol wrote no record this run)"
  exit 0
fi

echo "Broadcasting Deploy to chain $CHAIN_ID from $DEPLOYER"
export DEPLOYMENT_RECORD="$RECORD"
# A failed run removes its record: the script writes it during simulation, before the broadcast.
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" "${DEPLOY_ARGS[@]}" "${SIZE_ARGS[@]}" --broadcast --slow --skip test "${VERIFY_ARGS[@]}" -v \
  || { rm -f "$RECORD"; refuse "forge script failed; record removed"; }

POOL=$(jq -r '.pool' "$RECORD")
# The script records the simulation block; replace it with the block the pool landed in.
BROADCAST_FILE="${FOUNDRY_BROADCAST:-broadcast}/Deploy.s.sol/${CHAIN_ID}/run-latest.json"
POOL_TX=$(jq -r --arg a "${POOL,,}" '[.transactions[] | select((.contractAddress // "" | ascii_downcase) == $a)][0].hash' "$BROADCAST_FILE")
DEPLOY_BLOCK=$(cast receipt --rpc-url "$RPC_URL" "$POOL_TX" blockNumber)
DEPLOY_TIME=$(cast block --rpc-url "$RPC_URL" "$DEPLOY_BLOCK" --field timestamp)
jq --argjson b "$DEPLOY_BLOCK" --argjson t "$DEPLOY_TIME" '.blockNumber = $b | .deployedAt = $t' "$RECORD" > "$RECORD.tmp" && mv "$RECORD.tmp" "$RECORD"
LENS=$(jq -r '.lens // empty' "$RECORD")
if [[ "$CREATE_POOL" == "1" ]]; then
  # The local fork stands in for the FWA factory owner: zero (or EXPECTED_CREATION_FEE) creation
  # fee, no beta gate and room for repeated local pools. A live chain creates its pool from the
  # admin wallet.
  FACTORY_OWNER=$(cast call --rpc-url "$RPC_URL" "$FWA_FACTORY" 'owner()(address)')
  cast rpc --rpc-url "$RPC_URL" anvil_impersonateAccount "$FACTORY_OWNER" >/dev/null
  cast rpc --rpc-url "$RPC_URL" anvil_setBalance "$FACTORY_OWNER" 0xde0b6b3a7640000 >/dev/null
  cast send --rpc-url "$RPC_URL" --unlocked --from "$FACTORY_OWNER" "$FWA_FACTORY" 'setPoolCreationConfig(bool,uint256)' true "$EXPECTED_CREATION_FEE" >/dev/null
  cast send --rpc-url "$RPC_URL" --unlocked --from "$FACTORY_OWNER" "$FWA_FACTORY" 'setBetaAccess(bool)' false >/dev/null
  cast send --rpc-url "$RPC_URL" --unlocked --from "$FACTORY_OWNER" "$FWA_FACTORY" 'setMaxPoolsPerWallet(uint32)' 10 >/dev/null
  cast rpc --rpc-url "$RPC_URL" anvil_stopImpersonatingAccount "$FACTORY_OWNER" >/dev/null
  cast send --rpc-url "$RPC_URL" --unlocked --from "$ADMIN" "$POOL" 'createFwaPool(uint256)' "$EXPECTED_CREATION_FEE" >/dev/null
  FWA_POOL=$(cast call --rpc-url "$RPC_URL" "$POOL" 'fwaPool()(address)')
  OPENING_DEADLINE_AT=$(cast call --rpc-url "$RPC_URL" "$POOL" 'openingDeadlineAt()(uint256)' | awk '{print $1}')
  [[ "$OPENING_DEADLINE_AT" =~ ^[0-9]+$ && "$OPENING_DEADLINE_AT" != "0" ]] || refuse "opening deadline did not start"
  jq --arg fwa "${FWA_POOL,,}" --argjson at "$OPENING_DEADLINE_AT" '.fwaPool = $fwa | .openingDeadlineAt = $at' "$RECORD" > "$RECORD.tmp" && mv "$RECORD.tmp" "$RECORD"
  echo "FWA pool created at $FWA_POOL"
fi

FWA_POOL=$(jq -r '.fwaPool // empty' "$RECORD")
LIFECYCLES=(Opening Live Exiting Exported)
echo "record: $RECORD"
echo "readback: lifecycle=${LIFECYCLES[$(cast call --rpc-url "$RPC_URL" "$POOL" 'lifecycle()(uint8)')]} admin=$(cast call --rpc-url "$RPC_URL" "$POOL" 'admin()(address)') fwaPool=$(cast call --rpc-url "$RPC_URL" "$POOL" 'fwaPool()(address)') nav=$(cast call --rpc-url "$RPC_URL" "$POOL" 'nav()(uint256)')"
if [[ -n "$FWA_POOL" ]]; then
  echo "readback: fwaPool owner=$(cast call --rpc-url "$RPC_URL" "$FWA_POOL" 'owner()(address)') purchaseOperator=$(cast call --rpc-url "$RPC_URL" "$FWA_POOL" 'purchaseOperator()(address)')"
fi
echo "pool: https://evm.now/address/${POOL}?chainId=${CHAIN_ID}"
[[ -z "$LENS" ]] || echo "lens: https://evm.now/address/${LENS}?chainId=${CHAIN_ID}"
[[ -z "$FWA_POOL" ]] || echo "fwaPool: https://evm.now/address/${FWA_POOL}?chainId=${CHAIN_ID}"
