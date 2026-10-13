// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IShapes} from "shapes/interfaces/IShapes.sol";
import {ShapePacks} from "draw-packs/ShapePacks.sol";
import {ShapePackRenderer} from "draw-packs/ShapePackRenderer.sol";
import {IFWAClone} from "../../src/interfaces/IFWAClone.sol";
import {IFWACloneFactory} from "../../src/interfaces/IFWACloneFactory.sol";
import {IPool} from "../../src/interfaces/IPool.sol";

/// @dev The VRF consumer callback. The FWA VRF service is the registered Chainlink consumer and
///      forwards each word to the pool that paid for it.
interface IVrfConsumer {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
}

/// @dev `VRFConsumerBaseV2Plus.s_vrfCoordinator`, the only caller the FWA VRF service accepts a
///      callback from.
interface IVrfRouted {
    function s_vrfCoordinator() external view returns (address);
}

/// @notice Mainnet fork base. Forks Ethereum mainnet at `FORK_BLOCK` and exposes the deployed
///         Shapes collection and FWA factory, plus the factory-owner prank that opens pool
///         creation and purchases.
/// @dev `setUpFork()` reads `MAINNET_RPC_URL` (default: Tenderly public gateway) and `FORK_BLOCK`
///      from the environment. Addresses match `deployments/dependencies.json`, chain 1.
abstract contract ForkBase is Test {
    uint256 internal constant FORK_BLOCK = 26_170_000;

    address internal constant SHAPES_ADDR = 0x6fE9193276bF7aBCbEE44AB7aFd717d637D6FAf0;
    address internal constant FACTORY_ADDR = 0xF5A3A153164791AB579C3d9ba5DBECf7cDfd300c;
    address internal constant VRF_SERVICE_ADDR = 0xA4adFC35dB18326eFB3b5D9bf66A8103Ec2D5EE2;

    IShapes internal shapes = IShapes(SHAPES_ADDR);
    IFWACloneFactory internal factory = IFWACloneFactory(FACTORY_ADDR);
    ShapePacks internal drawPacks;

    function setUpFork() internal {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string("https://gateway.tenderly.co/public/mainnet"));
        vm.createSelectFork(rpc, vm.envOr("FORK_BLOCK", FORK_BLOCK));
        vm.chainId(31337);
    }

    /// @dev Pranks the factory owner to enable pool creation (no beta gate, zero fee), purchases
    ///      and VRF requests.
    function openFactory() internal {
        address factoryOwner = factory.owner();
        vm.startPrank(factoryOwner);
        factory.setBetaAccess(false);
        factory.setMaxPoolsPerWallet(10);
        factory.setPoolCreationConfig(true, 0);
        factory.setGlobalPurchasesEnabled(true);
        factory.setVrfRequestsPaused(false);
        vm.stopPrank();

        assertFalse(factory.betaAccess(), "betaAccess not disabled");
        assertEq(factory.maxPoolsPerWallet(), 10, "maxPoolsPerWallet mismatch");
        assertTrue(factory.poolCreationEnabled(), "poolCreationEnabled false");
        assertEq(factory.poolCreationFee(), 0, "poolCreationFee not 0");
        assertTrue(factory.globalPurchasesEnabled(), "globalPurchasesEnabled false");
        assertFalse(factory.vrfRequestsPaused(), "vrfRequestsPaused still true");
    }

    /// @dev Mints `qty` Shapes of `amountWei` backing to `to`, which must be an EOA or implement
    ///      `onERC721Received`.
    function mintShapes(address to, uint256 amountWei, uint256 qty) internal returns (uint256 firstId) {
        uint256 cost = qty * (amountWei + shapes.mintFee());
        vm.deal(to, to.balance + cost);
        vm.prank(to);
        firstId = shapes.mintBatchTo{value: cost}(amountWei, qty, to);
    }

    /// @dev Deploys the Draw Packs fork against the deployed Shapes with a two unit minimum pack and
    ///      stores it in `drawPacks`. The constructors need no further wiring.
    function deployDrawPacks(address admin) internal {
        ShapePackRenderer renderer = new ShapePackRenderer(SHAPES_ADDR);
        drawPacks = new ShapePacks(SHAPES_ADDR, address(renderer), admin, "Draw Packs", "DRAW", 2);
    }

    // ------------------------------------------------------------------ acquisitions

    function quote(IFWAClone pool) internal view returns (uint256 fee, uint256 vrf, uint256 total) {
        return pool.quoteAcquisitionPrice();
    }

    /// @dev Sends exactly `fee + vrf` with `maxAcquisitionFee = fee`, `minWeightedValue = 0`,
    ///      `maxNegativeSlippageBps = 10_000` and the live inventory version.
    function acquireAs(address caller, address purchaser, IFWAClone pool, uint256 deadline)
        internal
        returns (uint256 requestId)
    {
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice();
        uint256 version = pool.inventoryVersion();
        vm.deal(caller, caller.balance + total);
        vm.prank(caller);
        requestId = pool.acquire{value: total}(purchaser, fee, 0, 10_000, version, deadline);
    }

    /// @dev `maxNegativeSlippageBps` and `expectedInventoryVersion` that `pullWithShapes` passes to the
    ///      FWA pool: its own `selectionSlippageBps` and the live `inventoryVersion`. Read before a
    ///      `vm.prank` or `vm.expectRevert`, which apply to the next call.
    function poolArgs(IFWAClone fwa) internal view returns (uint256 slippageBps, uint256 version) {
        return (fwa.selectionSlippageBps(), fwa.inventoryVersion());
    }

    /// @dev `acquireBatch` of `count` through `pool_` as `who`, paying exactly the quoted total with
    ///      `maxAcquisitionFee` equal to the quoted fee and the pool-chosen arguments of `poolArgs`.
    ///      Returns the request ids.
    function acquirePooled(address pool_, IFWAClone fwa, address who, uint256 count)
        internal
        returns (uint256[] memory ids)
    {
        (uint256 fee,, uint256 total) = fwa.quoteAcquisitionPrice(count);
        (uint256 slip, uint256 version) = poolArgs(fwa);
        vm.deal(who, who.balance + total);
        uint64 last = fwa.lastIssuedSequence();
        vm.prank(who);
        IPool(pool_).acquireBatch{value: total}(who, count, fee, 0, slip, version, vm.getBlockTimestamp() + 1 hours);
        ids = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = fwa.requestIdAtSequence(last + 1 + uint64(i));
        }
    }

    /// @dev Delivers `word` the way a live fulfillment arrives: the coordinator calls the FWA VRF
    ///      service, which forwards the word to the pool. `processAcquisitions` is then cranked
    ///      until `requestId` reaches a terminal status.
    function fulfill(IFWAClone pool, uint256 requestId, uint256 word) internal {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        address service = pool.vrfService();
        vm.prank(IVrfRouted(service).s_vrfCoordinator());
        IVrfConsumer(service).rawFulfillRandomWords(requestId, words);

        for (uint256 i; i < 100; ++i) {
            (,,,, IFWAClone.AcquisitionStatus status) = pool.acquisitions(requestId);
            if (_isTerminal(status)) return;
            vm.roll(block.number + 1);
            pool.processAcquisitions(50);
        }
        revert("fulfill: request did not settle");
    }

    function _isTerminal(IFWAClone.AcquisitionStatus status) internal pure returns (bool) {
        return status == IFWAClone.AcquisitionStatus.Fulfilled || status == IFWAClone.AcquisitionStatus.Refunded
            || status == IFWAClone.AcquisitionStatus.Expired || status == IFWAClone.AcquisitionStatus.DeliveryPending
            || status == IFWAClone.AcquisitionStatus.DeliveryRefunded;
    }

    /// @dev Rolls past the request's word deadline with no callback delivered, then cranks it to Expired.
    function expire(IFWAClone pool, uint256 requestId) internal {
        vm.roll(block.number + pool.selectionTimeoutBlocks() + 2);
        pool.processAcquisitions(50);
        (,,,, IFWAClone.AcquisitionStatus status) = pool.acquisitions(requestId);
        assertEq(uint8(status), uint8(IFWAClone.AcquisitionStatus.Expired), "request did not expire");
    }

    function settleAll(IFWAClone pool) internal {
        uint256 iterations;
        while (pool.unsettledAcquisitionCount() != 0 && iterations < 200) {
            pool.processAcquisitions(50);
            vm.roll(block.number + 1);
            ++iterations;
        }
    }

    /// @dev Advances `block.timestamp` past the pool's inventory-change cooldown.
    function warpPastCooldown(IFWAClone pool) internal {
        vm.warp(pool.purchasesResumeAt() + 1);
    }

    // ------------------------------------------------------------------ selection targeting

    /// @dev Sum of weights of every Active listing whose slot is below `targetSlot`.
    function _cumulativeWeightBeforeSlot(IFWAClone pool, uint256 targetSlot) internal view returns (uint256 cum) {
        uint256 n = pool.nextListingId();
        for (uint256 id = 1; id < n; ++id) {
            (,,,, uint256 weight,, uint256 slot, IFWAClone.ListingStatus status) = pool.listings(id);
            if (status == IFWAClone.ListingStatus.Active && slot != 0 && slot < targetSlot) cum += weight;
        }
    }

    /// @dev Lowest random word that selects `listingId`.
    function wordFor(IFWAClone pool, uint256 listingId) internal view returns (uint256 word) {
        (,,,, uint256 weight,, uint256 slot, IFWAClone.ListingStatus status) = pool.listings(listingId);
        require(status == IFWAClone.ListingStatus.Active, "wordFor: listing not active");
        require(weight != 0, "wordFor: zero weight");
        word = _cumulativeWeightBeforeSlot(pool, slot);
    }

    /// @dev A word that selects some other active listing instead of `avoidListingId`.
    function wordAvoiding(IFWAClone pool, uint256 avoidListingId) internal view returns (uint256 word) {
        (,,,, uint256 weight,, uint256 slot,) = pool.listings(avoidListingId);
        uint256 total = pool.totalWeight();
        uint256 cum = _cumulativeWeightBeforeSlot(pool, slot);
        if (cum != 0) return 0;
        require(cum + weight < total, "wordAvoiding: no other active listing");
        word = cum + weight;
    }
}
