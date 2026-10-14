#!/usr/bin/env bash
# Local run on an anvil fork of mainnet (port 8545): script/local.sh <start|keeper|fulfill|stop>
#   start   fork, deploy, create the FWA pool, fund wallets, deposit, warp, open() until Live, print state
#   keeper  exec script/keeper.sh against the local record with the anvil keeper wallet (LOCAL_VRF=1 also runs fulfill each pass)
#   fulfill deliver a random word for every Pending FWA acquisition as the VRF coordinator, then processAcquisitions(20)
#   stop    kill anvil
# Env: FORK_RPC (default publicnode), LOCAL_OPENING_ETH (default 50), LOCAL_WALLET_ETH (default 1000),
# ONCE=1 and INTERVAL pass through to the keeper.
set -euo pipefail
cd "$(dirname "$0")/.."

PORT=8545
export RPC_URL="http://127.0.0.1:$PORT"
PIDFILE=".anvil-$PORT.pid"
RECORD="deployments/31337-$PORT.json"
# Anvil default accounts: 0 is the admin and deployer (script/env/anvil.env), 1 the keeper, 2 and 3 test wallets.
KEEPER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
WALLETS=(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC 0x90F79bf6EB2c4f870365E785982E1f101E93b906)

call() { cast call --rpc-url "$RPC_URL" "$@"; }
send() { cast send --rpc-url "$RPC_URL" --unlocked "$@" >/dev/null; }

stop() {
  [[ -f "$PIDFILE" ]] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
  rm -f "$PIDFILE"; echo "anvil stopped"
}

# Mirrors test/fork/ForkBase.sol fulfill: the sender is the VRF service's s_vrfCoordinator, the target is the VRF service.
fulfill() {
  local pool svc coord seq last rid st word
  pool=$(jq -r .fwaPool "$RECORD"); svc=$(call "$pool" 'vrfService()(address)'); coord=$(call "$svc" 's_vrfCoordinator()(address)')
  seq=$(call "$pool" 'nextSequenceToProcess()(uint64)' | awk '{print $1}'); last=$(call "$pool" 'lastIssuedSequence()(uint64)' | awk '{print $1}')
  cast rpc --rpc-url "$RPC_URL" anvil_impersonateAccount "$coord" >/dev/null
  cast rpc --rpc-url "$RPC_URL" anvil_setBalance "$coord" 0xde0b6b3a7640000 >/dev/null
  for (( ; seq <= last; seq++ )); do
    rid=$(call "$pool" 'requestIdAtSequence(uint64)(uint256)' "$seq" | awk '{print $1}')
    st=$(call "$pool" 'acquisitions(uint256)(address,uint256,uint256,uint256,uint8)' "$rid" | tail -1 | awk '{print $1}')
    [[ "$st" == 1 ]] || continue
    word=0x$(openssl rand -hex 32)
    # Explicit gas limit: the service defers delivery to the clone when gasleft() is below its callback reserve.
    send --gas-limit 3000000 --from "$coord" "$svc" 'rawFulfillRandomWords(uint256,uint256[])' "$rid" "[$word]"
    send --from "$KEEPER" "$pool" 'processAcquisitions(uint256)' 20
    st=$(call "$pool" 'acquisitions(uint256)(address,uint256,uint256,uint256,uint8)' "$rid" | tail -1 | awk '{print $1}')
    echo "$(date -u +%FT%TZ) fulfill seq=$seq requestId=$rid status=$st"
  done
}

start() {
  if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then echo "anvil already running (pid $(cat "$PIDFILE")); run stop first"; exit 1; fi
  nohup anvil --fork-url "${FORK_RPC:-https://ethereum-rpc.publicnode.com}" --port "$PORT" --chain-id 31337 >".anvil-$PORT.log" 2>&1 &
  echo $! >"$PIDFILE"
  for _ in $(seq 60); do cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1 && break; sleep 1; done
  cast chain-id --rpc-url "$RPC_URL" >/dev/null || { echo "anvil did not start, see .anvil-$PORT.log"; exit 1; }

  script/deploy.sh anvil
  POOL=$(jq -r .pool "$RECORD"); LENS=$(jq -r .lens "$RECORD"); FWA_POOL=$(jq -r .fwaPool "$RECORD")
  FACTORY=$(jq -r .fwaFactory "$RECORD"); ADMIN=$(jq -r .admin "$RECORD")

  # Factory owner sets inventoryChangeCooldown to 0 so settle may list.
  OWNER=$(call "$FACTORY" 'owner()(address)')
  cast rpc --rpc-url "$RPC_URL" anvil_impersonateAccount "$OWNER" >/dev/null
  cast rpc --rpc-url "$RPC_URL" anvil_setBalance "$OWNER" 0xde0b6b3a7640000 >/dev/null
  send --from "$OWNER" "$FACTORY" 'setInventoryChangeCooldown(uint32)' 0
  cast rpc --rpc-url "$RPC_URL" anvil_stopImpersonatingAccount "$OWNER" >/dev/null

  WALLET_WEI=$(cast to-wei "${LOCAL_WALLET_ETH:-1000}")
  for w in "$KEEPER" "${WALLETS[@]}"; do
    cast rpc --rpc-url "$RPC_URL" anvil_setBalance "$w" "$(cast to-hex "$WALLET_WEI")" >/dev/null
  done

  # Deposit the opening cohort, then warp past the opening deadline and open.
  send --from "$ADMIN" "$POOL" 'deposit()' --value "${LOCAL_OPENING_ETH:-50}ether"
  DEADLINE=$(call "$POOL" 'openingDeadlineAt()(uint256)' | awk '{print $1}')
  NOW=$(cast block --rpc-url "$RPC_URL" latest --field timestamp)
  if (( DEADLINE >= NOW )); then
    cast rpc --rpc-url "$RPC_URL" evm_increaseTime "$(( DEADLINE - NOW + 1 ))" >/dev/null
    cast rpc --rpc-url "$RPC_URL" evm_mine >/dev/null
  fi
  for i in $(seq 50); do
    [[ "$(call "$POOL" 'lifecycle()(uint8)')" == "1" ]] && break
    echo "open() call $i"; send --from "$ADMIN" "$POOL" 'open()'
  done
  [[ "$(call "$POOL" 'lifecycle()(uint8)')" == "1" ]] || { echo "pool is not Live after 50 open() calls"; exit 1; }

  echo "pool     $POOL"
  echo "lens     $LENS"
  echo "fwaPool  $FWA_POOL"
  echo "keeper   $KEEPER   wallets ${WALLETS[*]}"
  echo "quote(1) $(call "$LENS" 'quote(uint256)((uint256,uint256,uint256,bool))' 1)"
  echo "nav      $(call "$POOL" 'nav()(uint256)')"
  echo "settleDue $(call "$POOL" 'settleDue()(uint8)')  rotateDue $(call "$POOL" 'rotateDue()(uint8)')"
}

case "${1:-}" in
  start) start ;;
  keeper) DEPLOYMENT_RECORD="$RECORD" WALLET_MODE=anvil KEEPER="$KEEPER" exec script/keeper.sh ;;
  fulfill) fulfill ;;
  stop) stop ;;
  *) echo "usage: script/local.sh <start|keeper|fulfill|stop>"; exit 1 ;;
esac
