#!/usr/bin/env bash
# Full engine launch rehearsal on an anvil fork of mainnet: script/engine-local.sh <start|fulfill|play|stop>
#   start    fork at ENGINE_FORK_BLOCK, then broadcast every script/engine.sh step as real transactions:
#            deploy, round (and four founders fill it), coin (impersonating the Artcoins owner), lock,
#            bind, activate (after a real FWA holder sends the FWA pool creation fee), open, sponsor (a real
#            Wrapped Cryptopunk staked by the sponsor). Writes deployments/engine-31337.json.
#   fulfill  delivers a VRF word for every pending FWA acquisition as the coordinator, then processes.
#   play     N draws (default 20), a few coin trades and the treasury keeper calls, for a lived-in board.
#   stop     kills anvil.
# Impersonation stands for owner actions only (Artcoins owner launch, FWA holder transfer, VRF
# coordinator, a punk holder); every contract is the deployed one at the fork block.
set -euo pipefail
cd "$(dirname "$0")/.."

PORT=8546
export RPC_URL="http://127.0.0.1:$PORT"
PIDFILE=".anvil-$PORT.pid"
RECORD=deployments/engine-31337.json
BLOCK="${ENGINE_FORK_BLOCK:-26240000}"
FORK_RPC="${FORK_RPC:-https://mainnet.gateway.tenderly.co}"
KEEPER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
FOUNDERS=(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC 0x90F79bf6EB2c4f870365E785982E1f101E93b906 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc)
PLAYER=0x976EA74026E726554dB657fA54763abd0C3a0aa9
WPUNKS=0xb7F7F6C52F2e2fdb1963Eab30438024864c313F6
FWA_TOKEN=0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845
FWA_FACTORY=0xF5A3A153164791AB579C3d9ba5DBECf7cDfd300c

call() { cast call --rpc-url "$RPC_URL" "$@"; }
send() { cast send --rpc-url "$RPC_URL" --unlocked "$@" >/dev/null; }
impersonate() { cast rpc --rpc-url "$RPC_URL" anvil_impersonateAccount "$1" >/dev/null; cast rpc --rpc-url "$RPC_URL" anvil_setBalance "$1" 0x56BC75E2D63100000 >/dev/null; }
step() { BROADCAST=1 script/engine.sh anvil "$1"; }
num() { awk '{print $1}'; }
warp() { cast rpc --rpc-url "$RPC_URL" evm_increaseTime "$1" >/dev/null; cast rpc --rpc-url "$RPC_URL" evm_mine >/dev/null; }

stop() { [[ -f "$PIDFILE" ]] && kill "$(cat "$PIDFILE")" 2>/dev/null || true; rm -f "$PIDFILE"; echo "anvil stopped"; }

fulfill() {
  local pool svc coord seq last rid st
  pool=$(jq -r .fwaPool "$RECORD"); svc=$(call "$pool" 'vrfService()(address)'); coord=$(call "$svc" 's_vrfCoordinator()(address)')
  seq=$(call "$pool" 'nextSequenceToProcess()(uint64)' | num); last=$(call "$pool" 'lastIssuedSequence()(uint64)' | num)
  impersonate "$coord"
  for (( ; seq <= last; seq++ )); do
    rid=$(call "$pool" 'requestIdAtSequence(uint64)(uint256)' "$seq" | num)
    st=$(call "$pool" 'acquisitions(uint256)(address,uint256,uint256,uint256,uint8)' "$rid" | tail -1 | num)
    [[ "$st" == 1 ]] || continue
    send --gas-limit 3000000 --from "$coord" "$svc" 'rawFulfillRandomWords(uint256,uint256[])' "$rid" "[0x$(openssl rand -hex 32)]"
    send --from "$KEEPER" "$pool" 'processAcquisitions(uint256)' 20
  done
}

play() {
  local n="${1:-20}" pool lens fwa treasury
  pool=$(jq -r .pool "$RECORD"); lens=$(jq -r .lens "$RECORD"); fwa=$(jq -r .fwaPool "$RECORD"); treasury=$(jq -r .treasury "$RECORD")
  for (( i = 0; i < n; i++ )); do
    read -r fee _ total < <(call "$fwa" 'quoteAcquisitionPrice(uint256)(uint256,uint256,uint256)' 1 | num | tr '\n' ' ')
    slip=$(call "$fwa" 'selectionSlippageBps()(uint16)' | num); ver=$(call "$fwa" 'inventoryVersion()(uint256)' | num)
    now=$(cast block --rpc-url "$RPC_URL" latest --field timestamp)
    send --from "$PLAYER" --value "$total" "$pool" 'acquire(address,uint256,uint256,uint256,uint256,uint256)' "$PLAYER" "$fee" 0 "$slip" "$ver" $(( now + 3600 ))
    fulfill
    send --from "$KEEPER" "$pool" 'settle(uint256)' 20
  done
  warp 901
  [[ "$(call "$pool" 'rotateDue()(uint8)')" == "0" ]] || send --from "$KEEPER" "$pool" 'rotate()'
  send --from "$KEEPER" "$treasury" 'collectFees()' || true
  send --from "$KEEPER" "$treasury" 'harvest()' || true
  send --from "$KEEPER" "$treasury" 'boostGrail()' || true
  echo "draws $(call "$pool" 'grail()((uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint64,uint64,uint32,uint32))' | tr ',' '\n' | sed -n 10p)  nav $(call "$pool" 'nav()(uint256)')"
}

start() {
  if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then echo "anvil already running; stop first"; exit 1; fi
  nohup anvil --fork-url "$FORK_RPC" --fork-block-number "$BLOCK" --port "$PORT" --chain-id 31337 --gas-limit 100000000 >".anvil-$PORT.log" 2>&1 &
  echo $! >"$PIDFILE"
  for _ in $(seq 60); do cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1 && break; sleep 1; done
  rm -f "$RECORD"
  for w in "$KEEPER" "${FOUNDERS[@]}" "$PLAYER"; do cast rpc --rpc-url "$RPC_URL" anvil_setBalance "$w" 0x3635C9ADC5DEA00000 >/dev/null; done

  step deploy
  step round
  local round treasury pool target per
  round=$(jq -r .round "$RECORD"); treasury=$(jq -r .treasury "$RECORD"); pool=$(jq -r .pool "$RECORD")
  target=$(call "$round" 'target()(uint256)' | num); per=$(echo "$target / 4" | bc)
  for f in "${FOUNDERS[@]}"; do send --from "$f" --value "$per" "$round" 'contribute()'; done
  echo "round state $(call "$round" 'state()(uint8)') contributed $(call "$round" 'totalContributed()(uint256)')"

  impersonate "$(call 0x9b17bf6f97F5429368E11028BC637479b4667f7b 'owner()(address)')"
  step coin
  step lock
  step bind

  local fee holder
  fee=$(call "$FWA_FACTORY" 'poolCreationFee()(uint256)' | num); holder=$(call "$FWA_FACTORY" 'owner()(address)')
  impersonate "$holder"; send --from "$holder" "$FWA_TOKEN" 'transfer(address,uint256)' "$pool" "$fee"
  step activate
  warp $(( $(call "$pool" 'openingDeadlineAt()(uint256)' | num) - $(cast block --rpc-url "$RPC_URL" latest --field timestamp) + 1 ))
  step open

  # Sponsor: a real Wrapped Cryptopunk moved to the sponsor wallet, then staked through the page flow.
  step sponsor
  local s id ph
  s=$(jq -r .sponsorship "$RECORD"); id=$(call "$WPUNKS" 'tokenByIndex(uint256)(uint256)' 0 | num); ph=$(call "$WPUNKS" 'ownerOf(uint256)(address)' "$id")
  impersonate "$ph"; send --from "$ph" "$WPUNKS" 'transferFrom(address,address,uint256)' "$ph" "${FOUNDERS[2]}" "$id"
  send --from "${FOUNDERS[2]}" "$WPUNKS" 'approve(address,uint256)' "$s" "$id"
  send --from "${FOUNDERS[2]}" "$s" 'stake(uint256)' "$id"
  send --from "$KEEPER" "$pool" 'settle(uint256)' 20
  # Past the coin's sniper window, so the page shows baseline-skim trading.
  warp 10900
  BROADCAST=1 script/engine.sh anvil status
  echo "record $RECORD"
}

case "${1:-}" in
  start) start ;;
  fulfill) fulfill ;;
  play) play "${2:-20}" ;;
  stop) stop ;;
  *) echo "usage: script/engine-local.sh <start|fulfill|play [n]|stop>"; exit 1 ;;
esac
