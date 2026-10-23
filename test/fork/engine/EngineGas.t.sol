// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPool, IPoolTypes} from "../../../src/interfaces/IPool.sol";
import {EngineBase} from "./EngineBase.sol";

/// @notice Gas of the engine's heaviest transactions on the fork, against the 16,777,216 gas
///         per-transaction cap mainnet enforces since Fusaka (EIP-7825). Every call the launch or a
///         keeper must send has to fit under it with headroom.
contract EngineGasForkTest is EngineBase {
    uint256 internal constant TX_GAS_CAP = 16_777_216;
    /// @dev Intrinsic gas and calldata are outside `gasleft()` deltas; keep a margin for them.
    uint256 internal constant HEADROOM = 1_000_000;

    function setUp() public {
        setUpEngine();
    }

    function _fits(string memory what, uint256 used) internal {
        emit log_named_uint(what, used);
        assertLt(used + HEADROOM, TX_GAS_CAP, what);
    }

    function test_gas_launchAndKeeperCallsFitTheTransactionCap() public {
        _openAndFundRound(TARGET);
        _launchCoin();
        uint256 fee = _fundFwaFee();
        uint256 g = gasleft();
        vm.prank(owner);
        treasury.activate(fee);
        _fits("activate", g - gasleft());
        clone = ip.fwaPool();
        vm.warp(ip.openingDeadlineAt());
        uint256 maxOpen;
        for (uint256 i; ip.lifecycle() == IPoolTypes.Lifecycle.Opening; ++i) {
            g = gasleft();
            ip.open();
            uint256 used = g - gasleft();
            if (used > maxOpen) maxOpen = used;
        }
        _fits("open (heaviest call)", maxOpen);
        uint256 maxSettle;
        while (ip.settleDue() != IPoolTypes.SettleTrigger.None) {
            g = gasleft();
            vm.prank(keeper);
            ip.settle(20);
            uint256 used = g - gasleft();
            if (used > maxSettle) maxSettle = used;
        }
        _fits("settle listing a batch (heaviest)", maxSettle);
        vm.warp(vm.getBlockTimestamp() + 901);
        if (ip.rotateDue() != IPoolTypes.RotateTrigger.None) {
            g = gasleft();
            vm.prank(keeper);
            ip.rotate();
            _fits("rotate with GRAIL mints", g - gasleft());
        }
        // Enough GRAIL fund for pieces to merge into a second 5 ETH item and then a 10 ETH item.
        vm.deal(address(this), 12 ether);
        ip.fundGrail{value: 12 ether}();
        uint256 maxRotate;
        for (uint256 i; i < 12; ++i) {
            vm.warp(vm.getBlockTimestamp() + 901);
            if (ip.rotateDue() == IPoolTypes.RotateTrigger.None) continue;
            g = gasleft();
            vm.prank(keeper);
            ip.rotate();
            uint256 used = g - gasleft();
            if (used > maxRotate) maxRotate = used;
        }
        _fits("rotate with GRAIL mints and merges (heaviest)", maxRotate);
        warpPastCooldown(clone);
        (uint256 qfee,, uint256 total) = clone.quoteAcquisitionPrice(5);
        (uint256 slip, uint256 version) = poolArgs(clone);
        vm.deal(player, player.balance + total);
        g = gasleft();
        vm.prank(player);
        ip.acquireBatch{value: total}(player, 5, qfee, 0, slip, version, vm.getBlockTimestamp() + 1 hours);
        _fits("acquireBatch(5)", g - gasleft());
        settleAll(clone);
        _draws(30);
        vm.prank(owner);
        treasury.windDown();
        uint256 maxStep;
        while (!treasury.settled()) {
            vm.roll(block.number + 1);
            g = gasleft();
            treasury.windDownStep();
            uint256 used = g - gasleft();
            if (used > maxStep) maxStep = used;
        }
        _fits("windDownStep (heaviest)", maxStep);
    }
}
