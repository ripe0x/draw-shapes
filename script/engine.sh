#!/usr/bin/env bash
# Engine launch steps: script/engine.sh <anvil|mainnet> <step>
# Steps (script/DeployEngine.s.sol): deploy round coin lock bind activate open sponsor status.
# Every step is simulated first. It broadcasts only with BROADCAST=1, from the step's signer:
#   deploy -> DEPLOYER; round bind activate sponsor -> OWNER; coin -> ARTCOINS_SIGNER;
#   lock -> TOKEN_ADMIN; open status -> any (KEEPER or DEPLOYER).
# WALLET_MODE=keystore selects a Foundry keystore by name from KEYSTORE_ACCOUNT_<ROLE> in the shell
# (never in the env file). WALLET_MODE=anvil sends from unlocked or impersonated anvil accounts.
set -euo pipefail
cd "$(dirname "$0")/.."

ENV_NAME="${1:-}"; STEP="${2:-}"
[[ -n "$ENV_NAME" && -n "$STEP" ]] || { echo "usage: script/engine.sh <anvil|mainnet> <step>"; exit 1; }
ENV_FILE="script/env/engine.${ENV_NAME}.env"
[[ -f "$ENV_FILE" ]] || { echo "no env file: $ENV_FILE"; exit 1; }
set -a; source <(grep -vE '^[A-Za-z_][A-Za-z0-9_]*=$' "$ENV_FILE"); set +a
refuse() { echo "guard failed: $*"; exit 1; }

case "$STEP" in
  deploy) ROLE=DEPLOYER ;;
  round|bind|activate|sponsor) ROLE=OWNER ;;
  coin) ROLE=ARTCOINS_SIGNER ;;
  lock) ROLE=TOKEN_ADMIN ;;
  open|status) ROLE=${KEEPER:+KEEPER}; ROLE=${ROLE:-DEPLOYER} ;;
  *) refuse "unknown step $STEP" ;;
esac
SIGNER="${!ROLE:-}"
[[ -n "$SIGNER" ]] || refuse "$ROLE is empty in $ENV_FILE"

LIVE_CHAIN=$(cast chain-id --rpc-url "$RPC_URL") || refuse "cannot reach $RPC_URL"
[[ "$LIVE_CHAIN" == "$CHAIN_ID" ]] || refuse "RPC chain id $LIVE_CHAIN != $CHAIN_ID"

# Addresses from earlier steps come from the record.
if [[ -f "${DEPLOYMENT_RECORD:-}" ]]; then
  export TREASURY="${TREASURY:-$(jq -r '.treasury // empty' "$DEPLOYMENT_RECORD")}"
  C=$(jq -r '.coin // empty' "$DEPLOYMENT_RECORD"); [[ "$C" == "0x0000000000000000000000000000000000000000" ]] || export COIN="${COIN:-$C}"
fi
[[ "$STEP" == "deploy" || -n "${TREASURY:-}" ]] || refuse "TREASURY unknown: run deploy first or set it"
if [[ "$STEP" == "deploy" && -f "${DEPLOYMENT_RECORD:-}" && "${REDEPLOY:-0}" != "1" ]]; then
  refuse "$DEPLOYMENT_RECORD exists; set REDEPLOY=1 to replace it"
fi
export GIT_COMMIT=$(git rev-parse HEAD)

ARGS=(script/DeployEngine.s.sol:DeployEngine --sig "run(string)" "$STEP" --rpc-url "$RPC_URL" --sender "$SIGNER")
if [[ "${BROADCAST:-0}" == "1" ]]; then
  export DRY_RUN=0
  if [[ "$ENV_NAME" == "mainnet" ]]; then
    [[ "$(git branch --show-current)" == "main" ]] || refuse "mainnet broadcasts run from main"
    [[ -z "$(git status --porcelain)" ]] || refuse "working tree is not clean"
    [[ -n "${RPC_URL_BROADCAST:-}" ]] && ARGS[5]="$RPC_URL_BROADCAST"
  fi
  case "$WALLET_MODE" in
    anvil) ARGS+=(--broadcast --unlocked --with-gas-price 2000000000) ;;
    keystore)
      ACCT_VAR="KEYSTORE_ACCOUNT_${ROLE}"; ACCT="${!ACCT_VAR:-}"
      [[ -n "$ACCT" ]] || refuse "$ACCT_VAR is empty in the shell"
      ARGS+=(--broadcast --account "$ACCT") ;;
    *) refuse "unknown WALLET_MODE $WALLET_MODE" ;;
  esac
  echo "BROADCAST $STEP on chain $CHAIN_ID from $SIGNER"
else
  export DRY_RUN=1
  echo "DRY RUN $STEP on chain $CHAIN_ID as $SIGNER (no transaction is sent; BROADCAST=1 sends)"
fi
forge script "${ARGS[@]}"
