// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {SponsorOffer} from "../src/sponsor/SponsorOffer.sol";

/// @notice Deploys the standing offer (docs/SPONSOR.md) with the terms of one collection and reads every value back.
/// @dev Inputs are the `OFFER_*` variables of `script/env/offer.example.env`. The broadcaster must be
///      `OFFER_OWNER`, which owns the contract and sets the terms. When the broadcaster is also the pool
///      admin the script calls `Pool.setRegistrar(offer)`, otherwise it logs the `cast send` line for the
///      admin. `Shapes.setFeeRecipient` is a separate step by the Shapes admin. A broadcast run writes the
///      record the web app reads (`{offer, collection}`) to `OFFER_RECORD`, default
///      `deployments/<chainId>-offer.json`.
contract DeployOffer is Script {
    error GuardFailed(string reason);

    struct Terms {
        address pool;
        address owner;
        address collection;
        uint256 parkedPriceWei;
        uint256 floorWei;
        uint256 decayWeiPerPull;
        uint256 reclaimDelay;
        uint256 capWei;
        uint8 maxOpen;
    }

    function run() external returns (SponsorOffer) {
        return runWith(_terms());
    }

    /// @dev `run` with the terms supplied directly instead of read from the environment.
    function runWith(Terms memory t) public returns (SponsorOffer offer) {
        if (t.pool.code.length == 0) revert GuardFailed("OFFER_POOL has no code");
        if (t.collection.code.length == 0) revert GuardFailed("OFFER_COLLECTION has no code");

        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        if (broadcaster != t.owner) revert GuardFailed("broadcaster is not OFFER_OWNER");
        offer = new SponsorOffer(t.pool, IPool(t.pool).shapes(), t.owner);
        offer.setTerms(
            t.collection,
            SponsorOffer.Terms({
                parkedPriceWei: t.parkedPriceWei,
                floorWei: t.floorWei,
                decayWeiPerPull: t.decayWeiPerPull,
                reclaimDelay: t.reclaimDelay,
                capWei: t.capWei,
                maxOpen: t.maxOpen,
                enabled: true
            })
        );
        bool registrarSet = IPool(t.pool).admin() == broadcaster;
        if (registrarSet) IPool(t.pool).setRegistrar(address(offer));
        vm.stopBroadcast();

        _postflight(offer, t, registrarSet);
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) _writeRecord(offer, t);
        _log(offer, t, registrarSet);
    }

    function _terms() internal view returns (Terms memory t) {
        t.pool = vm.envAddress("OFFER_POOL");
        t.owner = vm.envAddress("OFFER_OWNER");
        t.collection = vm.envAddress("OFFER_COLLECTION");
        t.parkedPriceWei = vm.envUint("OFFER_PARKED_PRICE_WEI");
        t.floorWei = vm.envUint("OFFER_FLOOR_WEI");
        t.decayWeiPerPull = vm.envUint("OFFER_DECAY_WEI_PER_PULL");
        t.reclaimDelay = vm.envUint("OFFER_RECLAIM_DELAY");
        t.capWei = vm.envUint("OFFER_CAP_WEI");
        t.maxOpen = uint8(vm.envUint("OFFER_MAX_OPEN"));
    }

    function _postflight(SponsorOffer o, Terms memory t, bool registrarSet) internal view {
        SponsorOffer.Terms memory s = o.terms(t.collection);
        _eq(o.owner() == t.owner, "offer.owner");
        _eq(address(o.pool()) == t.pool, "offer.pool");
        _eq(o.shapes() == IPool(t.pool).shapes(), "offer.shapes");
        _eq(s.enabled, "terms.enabled");
        _eq(s.parkedPriceWei == t.parkedPriceWei, "terms.parkedPriceWei");
        _eq(s.floorWei == t.floorWei, "terms.floorWei");
        _eq(s.decayWeiPerPull == t.decayWeiPerPull, "terms.decayWeiPerPull");
        _eq(s.reclaimDelay == t.reclaimDelay, "terms.reclaimDelay");
        _eq(s.capWei == t.capWei, "terms.capWei");
        _eq(s.maxOpen == t.maxOpen, "terms.maxOpen");
        _eq(o.deals().length == 0, "offer.deals");
        if (registrarSet) _eq(IPool(t.pool).registrar() == address(o), "pool.registrar");
    }

    function _writeRecord(SponsorOffer o, Terms memory t) internal {
        string memory key = "offerRecord";
        vm.serializeAddress(key, "offer", address(o));
        string memory json = vm.serializeAddress(key, "collection", t.collection);
        string memory path = vm.envOr("OFFER_RECORD", string(""));
        if (bytes(path).length == 0) path = string.concat("deployments/", vm.toString(block.chainid), "-offer.json");
        vm.writeJson(json, path);
    }

    function _eq(bool ok, string memory what) internal pure {
        if (!ok) revert GuardFailed(what);
    }

    function _log(SponsorOffer o, Terms memory t, bool registrarSet) internal view {
        console2.log("SponsorOffer", address(o));
        console2.log("capWei", t.capWei);
        console2.log(
            string.concat(
                "next: as the Shapes admin, cast send <shapes> \"setFeeRecipient(address)\" ", vm.toString(address(o))
            )
        );
        if (!registrarSet) {
            console2.log("next: as the pool admin");
            console2.log(
                string.concat("cast send ", vm.toString(t.pool), " \"setRegistrar(address)\" ", vm.toString(address(o)))
            );
        }
        console2.log("next: sponsors approve the offer on the collection, then call take(collection, tokenId)");
    }
}
