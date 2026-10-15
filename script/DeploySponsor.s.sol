// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {FeeSplit} from "../src/sponsor/FeeSplit.sol";
import {SponsoredPrize} from "../src/sponsor/SponsoredPrize.sol";

/// @notice Deploys the contracts of one sponsored prize deal (docs/SPONSOR.md) and reads every value back.
/// @dev Inputs are the `SPONSOR_*` variables of `script/env/sponsor.example.env`. The broadcaster must be
///      `SPONSOR_OWNER`, which owns the new `FeeSplit` (or the existing one named by `SPONSOR_FEE_SPLIT`)
///      and calls `setSponsor` and `setPrize`. `reclaimAfter` is the deploy time plus
///      `SPONSOR_RECLAIM_DELAY`. `Shapes.setFeeRecipient`, `Pool.registerForeign` and `SponsoredPrize.start`
///      are separate steps by other callers.
contract DeploySponsor is Script {
    error GuardFailed(string reason);

    struct Terms {
        address pool;
        address owner;
        address sponsor;
        address collection;
        uint256 tokenId;
        uint256 parkedPriceWei;
        uint256 floorWei;
        uint256 decayWeiPerPull;
        uint256 reclaimDelay;
        uint256 capWei;
        address existingFeeSplit;
    }

    function run() external returns (FeeSplit feeSplit, SponsoredPrize prize) {
        Terms memory t = _terms();
        if (t.pool.code.length == 0) revert GuardFailed("SPONSOR_POOL has no code");
        if (t.collection.code.length == 0) revert GuardFailed("SPONSOR_COLLECTION has no code");
        if (t.capWei == 0) revert GuardFailed("SPONSOR_CAP_WEI is zero");

        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        if (broadcaster != t.owner) revert GuardFailed("broadcaster is not SPONSOR_OWNER");
        feeSplit = t.existingFeeSplit == address(0) ? new FeeSplit(t.owner) : FeeSplit(payable(t.existingFeeSplit));
        prize = new SponsoredPrize(
            t.pool,
            address(feeSplit),
            t.sponsor,
            t.capWei,
            t.collection,
            t.tokenId,
            t.parkedPriceWei,
            t.floorWei,
            t.decayWeiPerPull,
            block.timestamp + t.reclaimDelay
        );
        feeSplit.setSponsor(t.sponsor, t.capWei);
        feeSplit.setPrize(address(prize));
        vm.stopBroadcast();

        _postflight(feeSplit, prize, t);
        _log(feeSplit, prize, t);
    }

    function _terms() internal view returns (Terms memory t) {
        t.pool = vm.envAddress("SPONSOR_POOL");
        t.owner = vm.envAddress("SPONSOR_OWNER");
        t.sponsor = vm.envAddress("SPONSOR_SPONSOR");
        t.collection = vm.envAddress("SPONSOR_COLLECTION");
        t.tokenId = vm.envUint("SPONSOR_TOKEN_ID");
        t.parkedPriceWei = vm.envUint("SPONSOR_PARKED_PRICE_WEI");
        t.floorWei = vm.envUint("SPONSOR_FLOOR_WEI");
        t.decayWeiPerPull = vm.envUint("SPONSOR_DECAY_WEI_PER_PULL");
        t.reclaimDelay = vm.envUint("SPONSOR_RECLAIM_DELAY");
        t.capWei = vm.envUint("SPONSOR_CAP_WEI");
        t.existingFeeSplit = vm.envOr("SPONSOR_FEE_SPLIT", address(0));
    }

    function _postflight(FeeSplit f, SponsoredPrize p, Terms memory t) internal view {
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
        _eq(p.tokenId() == t.tokenId, "prize.tokenId");
        _eq(p.parkedPriceWei() == t.parkedPriceWei, "prize.parkedPriceWei");
        _eq(p.floorWei() == t.floorWei, "prize.floorWei");
        _eq(p.decayWeiPerPull() == t.decayWeiPerPull, "prize.decayWeiPerPull");
        _eq(p.reclaimAfter() > block.timestamp, "prize.reclaimAfter");
        _eq(p.listingId() == 0 && !p.active(), "prize is not started");
        _eq(uint8(p.phase()) == 0, "prize.phase is Parked");
    }

    function _eq(bool ok, string memory what) internal pure {
        if (!ok) revert GuardFailed(what);
    }

    function _log(FeeSplit f, SponsoredPrize p, Terms memory t) internal pure {
        console2.log("FeeSplit", address(f));
        console2.log("SponsoredPrize", address(p));
        console2.log("capWei", t.capWei);
        console2.log("next: Shapes.setFeeRecipient(address) with the FeeSplit above, as the Shapes admin");
    }
}
