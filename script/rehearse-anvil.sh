#!/usr/bin/env bash
# Local launch rehearsal on an anvil fork of mainnet (no keys: the deploy wallet and governance are
# impersonated). Starts anvil at FORK_BLOCK, runs script/deploy.sh anvil, then the launch sequence through
# the real timelock: open the market, fund the vault, fill the board, advance 48 h, open the game.
# Time travel happens only on this local fork.
set -euo pipefail
cd "$(dirname "$0")/.."
FORK_URL="${MAINNET_RPC_URL:-https://gateway.tenderly.co/public/mainnet}"
FORK_BLOCK="${FORK_BLOCK:-26279000}"
PORT="${PORT:-8545}"
R="http://127.0.0.1:${PORT}"
set -a; source script/env/anvil.env; set +a
# The rehearsal needs nothing from the network but the RPC: offline mode stops forge from waiting on signature lookups.
export FOUNDRY_OFFLINE=true
anvil --fork-url "$FORK_URL" --fork-block-number "$FORK_BLOCK" --chain-id 31337 --port "$PORT" --silent &
ANVIL=$!
# KEEP_ANVIL=1 leaves the fork running after the rehearsal (for the keeper or the site).
[[ "${KEEP_ANVIL:-0}" == "1" ]] || trap 'kill $ANVIL' EXIT
sleep 6
cast rpc anvil_setBalance "$DEPLOYER" 0x56BC75E2D63100000 --rpc-url "$R" >/dev/null
cast rpc anvil_impersonateAccount "$DEPLOYER" --rpc-url "$R" >/dev/null
RPC_URL="$R" script/deploy.sh anvil

J=deployments/31337-local.json
T=$(jq -r .timelock $J); V=$(jq -r .vault $J); G=$(jq -r .game $J); L=$(jq -r .liquidity $J); F=$(jq -r .farm $J); P=$(jq -r .fwaPool $J)
Z=0x$(printf '%064x' 0)
cast rpc anvil_setBalance "$GOVERNANCE" 0x56BC75E2D63100000 --rpc-url "$R" >/dev/null
cast rpc anvil_impersonateAccount "$GOVERNANCE" --rpc-url "$R" >/dev/null
tl() { # target value calldata salt: schedule and execute through the timelock (delay 0)
  local salt; salt=0x$(printf '%064x' "$4")
  cast send "$T" "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" "$1" "$2" "$3" "$Z" "$salt" 0 --from "$GOVERNANCE" --unlocked --rpc-url "$R" >/dev/null
  cast send "$T" "execute(address,uint256,bytes,bytes32,bytes32)" "$1" "$2" "$3" "$Z" "$salt" --value "$2" --from "$GOVERNANCE" --unlocked --rpc-url "$R" >/dev/null
}
OPENING="${OPENING_CAPITAL_WEI:-28000000000000000000}"
LAUNCH=0 # single-sided: no ETH is paired
cast rpc anvil_setBalance "$GOVERNANCE" 0x3635C9ADC5DEA00000 --rpc-url "$R" >/dev/null
tl "$L" "$LAUNCH" "$(cast calldata 'launch()')" 1
echo "market: launched=$(cast call "$L" 'launched()(bool)' --rpc-url "$R")"
cast send "$V" --value "$OPENING" --from "$GOVERNANCE" --unlocked --rpc-url "$R" >/dev/null
cast send "$V" "fund()" --from "$GOVERNANCE" --unlocked --rpc-url "$R" >/dev/null
for _ in 1 2 3 4 5 6; do cast send "$G" "sync(uint256)" 50 --from "$GOVERNANCE" --unlocked --gas-limit 15000000 --rpc-url "$R" >/dev/null 2>&1 || true; done
echo "board: $(cast call "$G" 'liveCount()(uint256)' --rpc-url "$R") listings, cash $(cast call "$G" 'cash()(uint256)' --rpc-url "$R")"
cast rpc evm_increaseTime 172800 --rpc-url "$R" >/dev/null; cast rpc anvil_mine 1 --rpc-url "$R" >/dev/null
tl "$G" 0 "$(cast calldata 'openGame()')" 2
echo "game: openBlock=$(cast call "$F" 'openBlock()(uint256)' --rpc-url "$R") purchases=$(cast call "$P" 'localPurchasesEnabled()(bool)' --rpc-url "$R")"
# one pull through FWA by an impersonated player, so the keeper has work
PLAYER=0x00000000000000000000000000000000000b1a7e
cast rpc anvil_setBalance "$PLAYER" 0x56BC75E2D63100000 --rpc-url "$R" >/dev/null
cast rpc anvil_impersonateAccount "$PLAYER" --rpc-url "$R" >/dev/null
read -r FEE _ TOTAL < <(cast call "$P" 'quoteAcquisitionPrice(uint256)(uint256,uint256,uint256)' 1 --rpc-url "$R" | awk '{print $1}' | tr '\n' ' '; echo)
VERSION=$(cast call "$P" 'inventoryVersion()(uint256)' --rpc-url "$R" | awk '{print $1}')
DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$R") + 3600 ))
# The quote ran at gas price 0, so it leaves out FWA's VRF fee (gas price x 1.95M); send a margin, FWA refunds the rest.
VALUE=$(( TOTAL + 10000000000000000 ))
cast send "$P" 'acquire(address,uint256,uint256,uint256,uint256,uint256)' "$PLAYER" "$FEE" 0 10000 "$VERSION" "$DEADLINE" --value "$VALUE" --from "$PLAYER" --unlocked --rpc-url "$R" >/dev/null
echo "pull: issued, lastIssuedSequence=$(cast call "$P" 'lastIssuedSequence()(uint64)' --rpc-url "$R")"
echo "rehearsal complete"
