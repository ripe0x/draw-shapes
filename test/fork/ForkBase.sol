// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IShapes} from "shapes/interfaces/IShapes.sol";
import {Denominations} from "shapes/lib/Denominations.sol";
import {IFWAClone, FWAConfigKeys} from "../../src/interfaces/IFWAClone.sol";
import {IFWACloneFactory} from "../../src/interfaces/IFWACloneFactory.sol";
import {IShapesVaultController as IC} from "../../src/interfaces/IShapesVaultController.sol";
import {Skim} from "../../src/PoolStore.sol";

/// @dev The VRF consumer callback. The FWA VRF service is the registered Chainlink consumer and
///      forwards each word to the pool that paid for it.
interface IVrfConsumer {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
}

/// @dev `VRFConsumerBaseV2Plus.s_vrfCoordinator`, the only caller the FWA VRF service accepts a
///      callback from. The service holds the Chainlink subscription; `FWAClone` routes through it
///      and names it as its own coordinator.
interface IVrfRouted {
    function s_vrfCoordinator() external view returns (address);
}

/// @notice Mainnet-fork harness for the FWA V2 standard custom pool (FWAClone) and its factory.
///         Every dependency is the real deployed contract at `FORK_BLOCK`: Shapes, the FWAFactory,
///         the FWAClone implementation and the FWA VRF service.
///
///         Run:
///           MAINNET_RPC_URL=https://gateway.tenderly.co/public/mainnet FORK_BLOCK=26040413 \
///             forge test --match-contract FwaV2Probe -vv
abstract contract ForkBase is Test {
    uint256 internal constant FORK_BLOCK = 26_040_413;

    address internal constant SHAPES_ADDR = 0x6fE9193276bF7aBCbEE44AB7aFd717d637D6FAf0;
    address internal constant FACTORY_ADDR = 0xF5A3A153164791AB579C3d9ba5DBECf7cDfd300c;
    address internal constant VRF_SERVICE_ADDR = 0xA4adFC35dB18326eFB3b5D9bf66A8103Ec2D5EE2;

    IShapes internal shapes = IShapes(SHAPES_ADDR);
    IFWACloneFactory internal factory = IFWACloneFactory(FACTORY_ADDR);

    /// @dev Minor at ladder index 5, major target at index 6 and the minor interval pinned to 1500
    ///      pulls (minimum equals maximum). Suites whose merge, reseed and board fixtures are written
    ///      around those sizes return this from their `_grailParams` override.
    ///      Mechanics fixture, not the shipped launch configuration.
    function _midLadderGrailParams() internal pure returns (IC.GrailParams memory p) {
        p = _launchGrailParams();
        p.minorRungIndex = 5;
        p.majorTargetRungIndex = 6;
        p.minorIntervalMinPulls = 1500;
        p.minorIntervalMaxPulls = 1500;
    }

    /// @dev The launch GRAIL track settings `script/env/*.env` pins (ECON-05).
    function _grailParams() internal pure virtual returns (IC.GrailParams memory) {
        return _launchGrailParams();
    }

    function _launchGrailParams() internal pure returns (IC.GrailParams memory) {
        return IC.GrailParams({
            minorRungIndex: 4,
            minorSeedNotionalBps: 5000,
            minorIntervalMinPulls: 100,
            minorIntervalMaxPulls: 100_000,
            reseedCapBps: 2500,
            majorTargetRungIndex: 4,
            majorStepUpDays: 7,
            majorStepDownDays: 60,
            majorNavMultiple: 4,
            majorDemandDays: 4,
            majorDecayWeiPerPull: 1e15,
            majorFloorUnits: 100
        });
    }

    function setUpFork() internal {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string("https://gateway.tenderly.co/public/mainnet"));
        vm.createSelectFork(rpc, vm.envOr("FORK_BLOCK", FORK_BLOCK));
        // Fork tests exercise local production mechanics under local chain ID 31337.
        vm.chainId(31337);
    }

    /*//////////////////////////////////////////////////////////////
                        FACTORY GOVERNANCE (owner pranks)
    //////////////////////////////////////////////////////////////*/

    /// @dev Opens the factory for pool creation and purchases. `setVrfRequestsPaused(false)` forwards
    ///      to the FWA VRF service's own `requestsPaused` internally (FWAFactory.sol:595-601,
    ///      `IFWACloneVRFServiceAdmin(vrfService).setRequestsPaused(paused)`), so no separate prank of
    ///      the VRF service is required even though it is a distinct contract the factory owns.
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

    /*//////////////////////////////////////////////////////////////
                              POOL CREATION
    //////////////////////////////////////////////////////////////*/

    function createPoolAs(address poolOwner, bytes32 salt) internal returns (IFWAClone pool) {
        uint256 fee = factory.poolCreationFee();
        vm.prank(poolOwner);
        address addr = factory.createPool(salt, fee);
        pool = IFWAClone(addr);

        assertEq(pool.owner(), poolOwner, "pool owner mismatch");
        assertTrue(factory.consumerReady(addr), "consumerReady false");

        vm.prank(poolOwner);
        pool.setBool(FWAConfigKeys.ACQUISITIONS_ENABLED, true);
    }

    /*//////////////////////////////////////////////////////////////
                                 SHAPES
    //////////////////////////////////////////////////////////////*/

    /// @dev Mints `qty` Shapes at `amountWei` backing to EOA `to`. `to` must be an EOA (or implement
    ///      `onERC721Received`) since `mintBatchTo` uses `_safeMint`.
    function mintShapes(address to, uint256 amountWei, uint256 qty) internal returns (uint256 firstId) {
        uint256 cost = qty * (amountWei + shapes.mintFee());
        vm.deal(to, to.balance + cost);
        vm.prank(to);
        firstId = shapes.mintBatchTo{value: cost}(amountWei, qty, to);
    }

    function listAs(address poolOwner, IFWAClone pool, uint256 tokenId, uint256 price)
        internal
        returns (uint256 listingId)
    {
        vm.startPrank(poolOwner);
        shapes.setApprovalForAll(address(pool), true);
        listingId = pool.listNFT(SHAPES_ADDR, tokenId, price);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                               ACQUISITIONS
    //////////////////////////////////////////////////////////////*/

    function quote(IFWAClone pool) internal view returns (uint256 fee, uint256 vrf, uint256 total) {
        return pool.quoteAcquisitionPrice();
    }

    /// @dev Sends exactly `fee + vrf`, `maxAcquisitionFee = fee`, `minWeightedValue = 0`,
    ///      `maxNegativeSlippageBps = 10000` (no downside slippage guard), `expectedInventoryVersion`
    ///      read live. Callers that need tighter slippage parameters call `pool.acquire` directly.
    function acquireAs(address caller, address purchaser, IFWAClone pool, uint256 deadline)
        internal
        returns (uint256 requestId)
    {
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice();
        vm.deal(caller, caller.balance + total);
        vm.prank(caller);
        requestId = pool.acquire{value: total}(purchaser, fee, 0, 10_000, pool.inventoryVersion(), deadline);
    }

    /// @dev Delivers `word` the way a live fulfillment arrives: the Chainlink coordinator calls the
    ///      FWA VRF service, which is the registered consumer, and the service forwards the word to
    ///      the pool. The service clears its prepared-request count on that callback and refuses a
    ///      new request once the subscription no longer covers the count
    ///      (`InsufficientVrfCoverage`). `processAcquisitions` is then cranked until `requestId`
    ///      reaches a terminal status; the fast path inside the callback itself may already settle
    ///      it (dossier fwa-v2.md section 8).
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

    /// @dev Launch skim this suite passes to the controller constructor: maintenance, the premium
    ///      curve floor and the GRAIL feed.
    function _skim() internal pure virtual returns (Skim memory) {
        return Skim({maintenanceBps: 0, premiumBps: 200, grailFeedBps: 200, grailMinorShareBps: 5000, reserveBps: 0});
    }

    /// @dev ECON-04 curve at its launch settings.
    function _premiumCurve() internal pure virtual returns (IC.PremiumCurve memory) {
        return IC.PremiumCurve({
            floorBps: 200,
            midBps: 350,
            topBps: 550,
            kneeLowBps: 1000,
            kneeMidBps: 2500,
            kneeHighBps: 5000,
            windowSeconds: 1 days,
            minPulls: 300,
            maxDays: 30
        });
    }

    /// @dev FLOW-13 and FLOW-05 settings. Off in the shared fixtures so suites that deposit after
    ///      launch finalization run ungated; gate suites turn them on through `setParams`.
    function _gateParams() internal pure virtual returns (IC.GateParams memory) {
        return IC.GateParams({gateDays: 0, launchCapDays: 0, launchCapQueueUnits: 0, minNavUnits: 0, openingCapUnits: 0, admissionFloorUnits: 0, dailyAdmissionUnits: 0});
    }

    /// @dev The launch values `script/env/*.env` pins.
    function _launchGateParams() internal pure returns (IC.GateParams memory) {
        return IC.GateParams({
            gateDays: 4,
            launchCapDays: 7,
            launchCapQueueUnits: 10_000,
            minNavUnits: 0,
            openingCapUnits: 0,
            admissionFloorUnits: 5_500,
            dailyAdmissionUnits: 0
        });
    }

    /// @dev Maintenance reserve floor at its launch setting (50 ladder units).
    function _maintenanceReserveWei() internal pure returns (uint256) {
        return 50 * Denominations.UNIT;
    }

    function _isTerminal(IFWAClone.AcquisitionStatus status) internal pure returns (bool) {
        return status == IFWAClone.AcquisitionStatus.Fulfilled
            || status == IFWAClone.AcquisitionStatus.Refunded || status == IFWAClone.AcquisitionStatus.Expired
            || status == IFWAClone.AcquisitionStatus.DeliveryPending
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

    /// @dev Advances `block.timestamp` past the pool's current inventory-change cooldown so a
    ///      subsequent `acquire` is not blocked by `InventoryChangeCooldownActive`.
    function warpPastCooldown(IFWAClone pool) internal {
        vm.warp(pool.purchasesResumeAt() + 1);
    }

    /*//////////////////////////////////////////////////////////////
                          SELECTION-TREE TARGETING
    //////////////////////////////////////////////////////////////*/

    /// @dev Sum of weights of every Active listing whose slot is below `targetSlot`. The segment tree
    ///      orders leaves by slot number (FWAClone.sol:1654-1715), so this equals the low end of the
    ///      target range `_selectSlot` resolves to `targetSlot`.
    function _cumulativeWeightBeforeSlot(IFWAClone pool, uint256 targetSlot)
        internal
        view
        returns (uint256 cum)
    {
        uint256 n = pool.nextListingId();
        for (uint256 id = 1; id < n; ++id) {
            (,,,, uint256 weight,, uint256 slot, IFWAClone.ListingStatus status) = pool.listings(id);
            if (status == IFWAClone.ListingStatus.Active && slot != 0 && slot < targetSlot) {
                cum += weight;
            }
        }
    }

    /// @dev Lowest random word that selects `listingId`: any word whose `% totalWeight` lands in
    ///      `[cum, cum + weight)` selects it; the cumulative low end itself always qualifies.
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
