// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {FeeSplit} from "../src/sponsor/FeeSplit.sol";
import {SponsoredPrize} from "../src/sponsor/SponsoredPrize.sol";

/// @notice Deploys the contracts of one sponsored prize deal (docs/SPONSOR.md) and reads every value back.
/// @dev Inputs are the `SPONSOR_*` variables of `script/env/sponsor.example.env`. The broadcaster must be
///      `SPONSOR_OWNER`, which owns the new `FeeSplit` (or the existing one named by `SPONSOR_FEE_SPLIT`)
///      and calls `setSponsor` and `setPrize`. When the broadcaster is also the pool admin the script
///      calls `Pool.setRegistrar(prize)`, otherwise it logs the `cast send` line for the admin.
///      `SPONSOR_RECLAIM_DELAY` is the delay from `SponsoredPrize.stake` to `reclaimAfter`.
///      `Shapes.setFeeRecipient` and `SponsoredPrize.stake` are separate steps by other callers. A broadcast run writes the deal record the web app reads
///      (`{feeSplit, prize, collection}`) to `SPONSOR_RECORD`, default
///      `deployments/<chainId>-sponsor.json`.
contract DeploySponsor is Script {
    error GuardFailed(string reason);

    struct Terms {
        address pool;
        address owner;
        address sponsor;
        address collection;
        uint256 parkedPriceWei;
        uint256 floorWei;
        uint256 decayWeiPerPull;
        uint256 reclaimDelay;
        uint256 capWei;
        address existingFeeSplit;
    }

    function run() external returns (FeeSplit, SponsoredPrize) {
        return runWith(_terms());
    }

    /// @dev `run` with the terms supplied directly instead of read from the environment.
    function runWith(Terms memory t) public returns (FeeSplit feeSplit, SponsoredPrize prize) {
        if (t.pool.code.length == 0) revert GuardFailed("SPONSOR_POOL has no code");
        if (t.collection.code.length == 0) revert GuardFailed("SPONSOR_COLLECTION has no code");
        if (t.capWei == 0) revert GuardFailed("SPONSOR_CAP_WEI is zero");

        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        if (broadcaster != t.owner) revert GuardFailed("broadcaster is not SPONSOR_OWNER");
        feeSplit = t.existingFeeSplit == address(0) ? new FeeSplit(t.owner) : FeeSplit(payable(t.existingFeeSplit));
        prize = _newPrize(t, address(feeSplit));
        feeSplit.setSponsor(t.sponsor, t.capWei);
        feeSplit.setPrize(address(prize));
        bool registrarSet = IPool(t.pool).admin() == broadcaster;
        if (registrarSet) IPool(t.pool).setRegistrar(address(prize));
        vm.stopBroadcast();

        _postflight(feeSplit, prize, t, registrarSet);
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) _writeRecord(feeSplit, prize, t);
        _log(feeSplit, prize, t, registrarSet);
    }

    /// @dev The constructor arguments are encoded in two halves to stay inside the stack limit.
    function _newPrize(Terms memory t, address feeSplit) internal returns (SponsoredPrize prize) {
        bytes memory code = bytes.concat(
            type(SponsoredPrize).creationCode,
            abi.encode(t.pool, feeSplit, t.sponsor, t.capWei, t.collection),
            abi.encode(t.parkedPriceWei, t.floorWei, t.decayWeiPerPull, t.reclaimDelay)
        );
        address deployed;
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            deployed := create(0, add(code, 0x20), mload(code))
        }
        if (deployed == address(0)) revert GuardFailed("SponsoredPrize deployment failed");
        prize = SponsoredPrize(payable(deployed));
    }

    function _terms() internal view returns (Terms memory t) {
        t.pool = vm.envAddress("SPONSOR_POOL");
        t.owner = vm.envAddress("SPONSOR_OWNER");
        t.sponsor = vm.envAddress("SPONSOR_SPONSOR");
        t.collection = vm.envAddress("SPONSOR_COLLECTION");
        t.parkedPriceWei = vm.envUint("SPONSOR_PARKED_PRICE_WEI");
        t.floorWei = vm.envUint("SPONSOR_FLOOR_WEI");
        t.decayWeiPerPull = vm.envUint("SPONSOR_DECAY_WEI_PER_PULL");
        t.reclaimDelay = vm.envUint("SPONSOR_RECLAIM_DELAY");
        t.capWei = vm.envUint("SPONSOR_CAP_WEI");
        t.existingFeeSplit = vm.envOr("SPONSOR_FEE_SPLIT", address(0));
    }

    function _postflight(FeeSplit f, SponsoredPrize p, Terms memory t, bool registrarSet) internal view {
        _eq(f.owner() == t.owner, "feeSplit.owner");
        _eq(f.sponsor() == t.sponsor, "feeSplit.sponsor");
        _eq(f.capWei() == t.capWei, "feeSplit.capWei");
        _eq(f.paidWei() == 0, "feeSplit.paidWei");
        _eq(f.prize() == address(p), "feeSplit.prize");
        _eq(address(p.pool()) == t.pool, "prize.pool");
        _eq(address(p.feeSplit()) == address(f), "prize.feeSplit");
        _eq(p.sponsor() == t.sponsor, "prize.sponsor");
        _eq(p.capWei() == t.capWei, "prize.capWei");
        _eq(p.collection() == t.collection, "prize.collection");
        _eq(p.tokenId() == 0, "prize.tokenId");
        _eq(p.parkedPriceWei() == t.parkedPriceWei, "prize.parkedPriceWei");
        _eq(p.floorWei() == t.floorWei, "prize.floorWei");
        _eq(p.decayWeiPerPull() == t.decayWeiPerPull, "prize.decayWeiPerPull");
        _eq(p.reclaimDelay() == t.reclaimDelay, "prize.reclaimDelay");
        _eq(!p.staked() && !p.active(), "prize is not staked");
        if (registrarSet) _eq(IPool(t.pool).registrar() == address(p), "pool.registrar");
        _eq(uint8(p.phase()) == 0, "prize.phase is Parked");
    }

    function _writeRecord(FeeSplit f, SponsoredPrize p, Terms memory t) internal {
        string memory key = "sponsorRecord";
        vm.serializeAddress(key, "feeSplit", address(f));
        vm.serializeAddress(key, "prize", address(p));
        string memory json = vm.serializeAddress(key, "collection", t.collection);
        string memory path = vm.envOr("SPONSOR_RECORD", string(""));
        if (bytes(path).length == 0) path = string.concat("deployments/", vm.toString(block.chainid), "-sponsor.json");
        vm.writeJson(json, path);
    }

    function _eq(bool ok, string memory what) internal pure {
        if (!ok) revert GuardFailed(what);
    }

    function _log(FeeSplit f, SponsoredPrize p, Terms memory t, bool registrarSet) internal view {
        console2.log("FeeSplit", address(f));
        console2.log("SponsoredPrize", address(p));
        console2.log("capWei", t.capWei);
        console2.log("next: Shapes.setFeeRecipient(address) with the FeeSplit above, as the Shapes admin");
        if (!registrarSet) {
            console2.log("next: as the pool admin");
            console2.log(
                string.concat("cast send ", vm.toString(t.pool), " \"setRegistrar(address)\" ", vm.toString(address(p)))
            );
        }
        console2.log(
            "next: the sponsor approves the prize on the collection, then calls stake(tokenId) with any token of the collection it owns"
        );
    }
}
