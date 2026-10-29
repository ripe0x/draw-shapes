#!/usr/bin/env bash
# The one deploy wrapper: script/deploy.sh <anvil|sepolia|mainnet>
# Sources script/env/<env>.env (values only), evaluates guards, simulates, and broadcasts one transaction at
# a time. Deploy.s.sol runs preflight before and postflight after the deployment inside the simulation, so a
# mismatch stops the run before anything is sent. DRY_RUN=1 simulates without a wallet or broadcast.
# Secrets never enter env files or argv: the keystore is selected by account name; ETHERSCAN_API_KEY and
# KEYSTORE_PASSWORD_FILE come from the shell only. This script never broadcasts to mainnet unless the
# operator runs it with DRY_RUN unset and their own keystore.
set -euo pipefail
cd "$(dirname "$0")/.."

ENV_NAME="${1:-}"
[[ -n "$ENV_NAME" ]] || { echo "usage: script/deploy.sh <anvil|sepolia|mainnet>"; exit 1; }
ENV_FILE="script/env/${ENV_NAME}.env"
[[ -f "$ENV_FILE" ]] || { echo "no env file: $ENV_FILE"; exit 1; }
set -a; source <(grep -vE '^[A-Za-z_][A-Za-z0-9_]*=$' "$ENV_FILE"); set +a
DRY_RUN="${DRY_RUN:-0}"
RPC_URL="${RPC_URL:-${RPC_URL_DEFAULT:-}}"

refuse() { echo "guard failed: $*"; exit 1; }
warn_or_refuse() {
  echo "guard failed: $*"
  if [[ "$DRY_RUN" == "1" ]]; then echo "(DRY_RUN: continuing)"; else exit 1; fi
}

REQUIRED=(CHAIN_ID RPC_URL DEPLOYER GOVERNANCE SHAPES FWA_FACTORY FWA_IMPLEMENTATION POOL_MANAGER LADDER START_TICK)
for v in "${REQUIRED[@]}"; do
  [[ -n "${!v:-}" ]] || refuse "$v is empty in $ENV_FILE"
done
[[ "${GOVERNANCE,,}" != "${DEPLOYER,,}" ]] || refuse "GOVERNANCE must differ from DEPLOYER (nothing may stay with the deploy wallet)"
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
fi

case "${WALLET_MODE:-keystore}" in
  anvil) [[ "$ENV_NAME" == "anvil" ]] || refuse "WALLET_MODE=anvil is only valid for the anvil environment" ;;
  keystore) [[ "$DRY_RUN" == "1" || -n "${KEYSTORE_ACCOUNT:-}" ]] || refuse "KEYSTORE_ACCOUNT is empty" ;;
  *) refuse "unknown WALLET_MODE ${WALLET_MODE:-}" ;;
esac

# The build must carry the ladder the environment expects.
forge config --json 2>/dev/null | jq -e --arg l "ladders/${LADDER}/" '.remappings | any(contains("ladder/=") and contains($l))' >/dev/null \
  || refuse "forge config does not remap ladder/ to lib/shapes/ladders/${LADDER} (profile ${FOUNDRY_PROFILE:-default})"

LIVE_CHAIN=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null) || refuse "cannot reach RPC $RPC_URL"
[[ "$LIVE_CHAIN" == "$CHAIN_ID" || ( "$ENV_NAME" == "anvil" && "$LIVE_CHAIN" == "1" ) ]] || refuse "RPC chain id $LIVE_CHAIN != $CHAIN_ID"

for entry in "SHAPES:$SHAPES" "FWA_FACTORY:$FWA_FACTORY" "POOL_MANAGER:$POOL_MANAGER" "SHAPE_PACKS:${SHAPE_PACKS:-}"; do
  LABEL="${entry%%:*}"; ADDRESS="${entry#*:}"
  [[ -n "$ADDRESS" ]] || continue
  CODE=$(cast code --rpc-url "$RPC_URL" "$ADDRESS" 2>/dev/null || echo "0x")
  [[ "$CODE" != "0x" ]] || refuse "$LABEL has no code on chain $CHAIN_ID"
done
LIVE_IMPLEMENTATION=$(cast call --rpc-url "$RPC_URL" "$FWA_FACTORY" 'implementation()(address)') || refuse "FWA_FACTORY does not expose implementation()"
[[ "${LIVE_IMPLEMENTATION,,}" == "${FWA_IMPLEMENTATION,,}" ]] || refuse "FWA factory implementation $LIVE_IMPLEMENTATION != $FWA_IMPLEMENTATION"
if [[ -n "${FWA_VRF_SERVICE:-}" ]]; then
  LIVE_VRF=$(cast call --rpc-url "$RPC_URL" "$FWA_FACTORY" 'vrfService()(address)') || refuse "FWA_FACTORY does not expose vrfService()"
  [[ "${LIVE_VRF,,}" == "${FWA_VRF_SERVICE,,}" ]] || refuse "FWA VRF service $LIVE_VRF != $FWA_VRF_SERVICE"
fi

if [[ "${REQUIRE_MAIN_BRANCH:-0}" == "1" ]]; then
  BRANCH=$(git branch --show-current)
  [[ "$BRANCH" == "main" ]] || warn_or_refuse "not on main (on $BRANCH)"
  [[ -z "$(git status --porcelain)" ]] || warn_or_refuse "working tree not clean"
fi
if git ls-files --error-unmatch .env >/dev/null 2>&1; then refuse ".env is tracked"; fi

# Holders must fit EIP-170.
forge build --skip test
for c in FwaGame PoolOwner GenesisFarm ProtocolLiquidity Buyback KeeperFund PrizeVault EngineToken EngineHook Lens; do
  SIZE=$(( ($(forge inspect "$c" deployedBytecode | wc -c) - 3) / 2 ))
  (( SIZE <= 24576 )) || refuse "$c runtime is $SIZE bytes, over 24576"
done

export GIT_COMMIT; GIT_COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
if [[ "$ENV_NAME" == "anvil" ]]; then RECORD="deployments/${CHAIN_ID}-local.json"; else RECORD="deployments/${CHAIN_ID}.json"; fi

if [[ "$DRY_RUN" == "1" ]]; then
  DRY_RECORD="deployments/.dry-run-${CHAIN_ID}-$$.json"
  trap 'rm -f "$DRY_RECORD"' EXIT
  export DEPLOYMENT_RECORD="$DRY_RECORD"
  echo "DRY_RUN: simulating Deploy for chain $CHAIN_ID as $DEPLOYER"
  forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --sender "$DEPLOYER" --skip test -v
  echo "DRY_RUN: would-be record:"; cat "$DRY_RECORD"
  exit 0
fi

case "${WALLET_MODE:-keystore}" in
  anvil) DEPLOY_ARGS=(--unlocked --sender "$DEPLOYER") ;;
  keystore)
    if [[ -n "${KEYSTORE_PASSWORD_FILE:-}" ]]; then
      DEPLOY_ARGS=(--account "$KEYSTORE_ACCOUNT" --password-file "$KEYSTORE_PASSWORD_FILE" --sender "$DEPLOYER")
    else
      DEPLOY_ARGS=(--account "$KEYSTORE_ACCOUNT" --sender "$DEPLOYER")
    fi ;;
esac
VERIFY_ARGS=()
if [[ "${VERIFY:-0}" == "1" ]]; then
  [[ -n "${ETHERSCAN_API_KEY:-}" ]] || refuse "ETHERSCAN_API_KEY not in the shell environment"
  VERIFY_ARGS=(--verify)
fi

echo "Broadcasting Deploy to chain $CHAIN_ID from $DEPLOYER"
export DEPLOYMENT_RECORD="$RECORD"
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" "${DEPLOY_ARGS[@]}" --broadcast --slow --skip test "${VERIFY_ARGS[@]}" -v \
  || { rm -f "$RECORD"; refuse "forge script failed; record removed"; }

# Live readback after the broadcast.
G=$(jq -r .game "$RECORD"); T=$(jq -r .timelock "$RECORD"); P=$(jq -r .fwaPool "$RECORD"); E=$(jq -r .engine "$RECORD")
echo "record: $RECORD"
echo "readback: engine supply=$(cast call --rpc-url "$RPC_URL" "$E" 'totalSupply()(uint256)') game.governance=$(cast call --rpc-url "$RPC_URL" "$G" 'governance()(address)') timelock=$T"
echo "readback: poolOwner=$(jq -r .poolOwner "$RECORD") fwaPool=$P owner=$(cast call --rpc-url "$RPC_URL" "$P" 'owner()(address)') purchaseOperator=$(cast call --rpc-url "$RPC_URL" "$P" 'purchaseOperator()(address)')"
