#!/usr/bin/env bash
# Keeper loop: settle, rotate and payClaims on the pool, one log line per sent transaction.
# Env: RPC_URL, POOL or DEPLOYMENT_RECORD (reads .pool), KEEPER, INTERVAL (default 15), ONCE=1 for one pass.
# SPONSOR_PRIZE, SHAPES and FEE_SPLIT (all three) add two steps to each pass: Shapes.withdrawFees(FEE_SPLIT)
# when feesOwedTo(FEE_SPLIT) is nonzero, and SponsoredPrize.tick() while the prize is active, Hot and not atFloor.
# SPONSOR_OFFER and SHAPES add the same fee step for the standing offer: Shapes.withdrawFees(SPONSOR_OFFER) when owed,
# and tick(id) for every deal whose phase is Hot and not atFloor.
# LOCAL_VRF=1 runs `script/local.sh fulfill` at the start of every pass (anvil only).
# WALLET_MODE=anvil sends with --unlocked --from $KEEPER. WALLET_MODE=keystore sends with
# --account $KEYSTORE_ACCOUNT and --password-file $KEYSTORE_PASSWORD_FILE (shell only, never a key in argv).
set -euo pipefail

: "${RPC_URL:?RPC_URL is required}"
POOL="${POOL:-$(jq -er '.pool' "${DEPLOYMENT_RECORD:?POOL or DEPLOYMENT_RECORD is required}")}"
INTERVAL="${INTERVAL:-15}"
CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")

case "${WALLET_MODE:-keystore}" in
  anvil) : "${KEEPER:?KEEPER is required}"; WALLET=(--unlocked --from "$KEEPER") ;;
  keystore)
    : "${KEYSTORE_ACCOUNT:?KEYSTORE_ACCOUNT is required}"
    WALLET=(--account "$KEYSTORE_ACCOUNT")
    [[ -z "${KEYSTORE_PASSWORD_FILE:-}" ]] || WALLET+=(--password-file "$KEYSTORE_PASSWORD_FILE")
    KEEPER="${KEEPER:-$(cast wallet address --account "$KEYSTORE_ACCOUNT" ${KEYSTORE_PASSWORD_FILE:+--password-file "$KEYSTORE_PASSWORD_FILE"})}" ;;
  *) echo "unknown WALLET_MODE ${WALLET_MODE:-}"; exit 1 ;;
esac

SETTLED_TOPIC=$(cast keccak 'Settled(uint8,uint256,uint256)')
ROTATED_TOPIC=$(cast keccak 'Rotated(bool,bool,uint256)')

ROTATE_AFTER=0
LAST_DATA=
log() { echo "$(date -u +%FT%TZ) $*"; }

# send <label> <event topic or ""> <signature> [args...]: simulate with eth_call, then send to $TARGET (default $POOL).
send() {
  local label=$1 topic=$2 to=${TARGET:-$POOL}; shift 2
  if ! cast call --rpc-url "$RPC_URL" --from "$KEEPER" "$to" "$@" >/dev/null 2>&1; then
    log "$label skipped: simulation reverts"; return 0
  fi
  local out
  if ! out=$(cast send --json --rpc-url "$RPC_URL" "${WALLET[@]}" "$to" "$@" 2>&1); then
    log "$label failed: $(tr '\n' ' ' <<<"$out" | cut -c1-200)"; return 0
  fi
  local tx gas refund=n/a data
  tx=$(jq -r '.transactionHash' <<<"$out")
  gas=$(cast to-dec "$(jq -r '.gasUsed' <<<"$out")")
  if [[ -n "$topic" ]]; then
    data=$(jq -r --arg t "$topic" --arg p "${POOL,,}" '[.logs[] | select((.address|ascii_downcase)==$p and .topics[0]==$t)][0].data // empty' <<<"$out")
    # refund is the last 32-byte word of the event data
    [[ -z "$data" ]] || refund=$(cast to-dec "0x${data: -64}")
    LAST_DATA=$data
  fi
  log "$label status=$(jq -r '.status' <<<"$out") gas=$gas refundWei=$refund https://evm.now/tx/${tx}?chainId=${CHAIN_ID}"
}

pass() {
  local settle rotate head cash
  [[ "${LOCAL_VRF:-0}" != 1 ]] || "$(dirname "$0")/local.sh" fulfill
  settle=$(cast call --rpc-url "$RPC_URL" "$POOL" 'settleDue()(uint8)')
  [[ "$settle" == "0" ]] || send "settle(20) reason=$settle" "$SETTLED_TOPIC" 'settle(uint256)' 20
  rotate=$(cast call --rpc-url "$RPC_URL" "$POOL" 'rotateDue()(uint8)')
  # A rotate that leaves inventory unchanged keeps its reason true: back off one rotateInterval after it.
  if [[ "$rotate" != "0" ]] && (( $(date +%s) >= ROTATE_AFTER )); then
    LAST_DATA=
    send "rotate reason=$rotate" "$ROTATED_TOPIC" 'rotate()'
    if [[ -n "$LAST_DATA" && "${LAST_DATA:66:64}" == "$(printf '0%.0s' {1..64})" ]]; then
      local wait; wait=$(cast call --rpc-url "$RPC_URL" "$POOL" 'rotateInterval()(uint256)' | awk '{print $1}')
      ROTATE_AFTER=$(( $(date +%s) + wait ))
      log "rotate changed no inventory; next attempt in ${wait}s"
    fi
  fi
  # claimQueue(head) reverts when the head is past the end of the queue.
  head=$(cast call --rpc-url "$RPC_URL" "$POOL" 'claimHead()(uint256)')
  cash=$(cast call --rpc-url "$RPC_URL" "$POOL" 'cash()(uint256)' | awk '{print $1}')
  if [[ "$cash" != "0" ]] && cast call --rpc-url "$RPC_URL" "$POOL" 'claimQueue(uint256)(address,uint64,uint256)' "$head" >/dev/null 2>&1; then
    send "payClaims head=$head" "" 'payClaims()'
  fi
  if [[ -n "${SPONSOR_PRIZE:-}" && -n "${SHAPES:-}" && -n "${FEE_SPLIT:-}" ]]; then
    local fees
    fees=$(cast call --rpc-url "$RPC_URL" "$SHAPES" 'feesOwedTo(address)(uint256)' "$FEE_SPLIT" | awk '{print $1}')
    [[ "$fees" == "0" ]] || TARGET=$SHAPES send "withdrawFees($FEE_SPLIT) pendingWei=$fees" "" 'withdrawFees(address)' "$FEE_SPLIT"
    # phase() is 1 in Hot. tick() does nothing in Parked, after a capture or once atFloor() is true.
    if [[ "$(cast call --rpc-url "$RPC_URL" "$SPONSOR_PRIZE" 'active()(bool)')" == "true" \
       && "$(cast call --rpc-url "$RPC_URL" "$SPONSOR_PRIZE" 'atFloor()(bool)')" == "false" \
       && "$(cast call --rpc-url "$RPC_URL" "$SPONSOR_PRIZE" 'phase()(uint8)')" == "1" ]]; then
      TARGET=$SPONSOR_PRIZE send "tick" "" 'tick()'
    fi
  fi
  if [[ -n "${SPONSOR_OFFER:-}" && -n "${SHAPES:-}" ]]; then
    local ofees n id deal
    ofees=$(cast call --rpc-url "$RPC_URL" "$SHAPES" 'feesOwedTo(address)(uint256)' "$SPONSOR_OFFER" | awk '{print $1}')
    [[ "$ofees" == "0" ]] || TARGET=$SHAPES send "withdrawFees($SPONSOR_OFFER) pendingWei=$ofees" "" 'withdrawFees(address)' "$SPONSOR_OFFER"
    # phase(id) is 1 in Hot. deal(id) is a static struct of 17 words; word 13 is atFloor.
    n=$(cast call --rpc-url "$RPC_URL" "$SPONSOR_OFFER" 'dealCount()(uint256)' | awk '{print $1}')
    for ((id = 0; id < n; id++)); do
      deal=$(cast call --rpc-url "$RPC_URL" "$SPONSOR_OFFER" 'deal(uint256)' "$id")
      if [[ "$(cast call --rpc-url "$RPC_URL" "$SPONSOR_OFFER" 'active(uint256)(bool)' "$id")" == "true" \
         && "$(cast call --rpc-url "$RPC_URL" "$SPONSOR_OFFER" 'phase(uint256)(uint8)' "$id")" == "1" \
         && "${deal:$((2 + 64 * 13 + 63)):1}" == "0" ]]; then
        TARGET=$SPONSOR_OFFER send "tick($id)" "" 'tick(uint256)' "$id"
      fi
    done
  fi
}

log "keeper pool=$POOL keeper=$KEEPER chainId=$CHAIN_ID interval=${INTERVAL}s"
while true; do
  pass || log "pass failed"
  [[ "${ONCE:-0}" != "1" ]] || break
  sleep "$INTERVAL"
done
