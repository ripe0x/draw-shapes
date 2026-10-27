// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {KeeperFund} from "../../src/treasury/KeeperFund.sol";
import {Governed} from "../../src/Governed.sol";

/// @dev Stands in for the game: the overflow recipient.
contract OverflowStub {
    uint256 public returned;

    function returnOps() external payable {
        returned += msg.value;
    }
}

contract Rejecter {
    receive() external payable {
        revert();
    }
}

contract KeeperFundTest is Test {
    address tl = makeAddr("timelock");
    address payer = makeAddr("payer");
    KeeperFund kf;
    OverflowStub game;

    function _params() internal pure returns (KeeperFund.Params memory) {
        return KeeperFund.Params(2_000, 30 gwei, 0.01 ether, 0.002 ether, 6 hours, 40_000, 0.5 ether, 0);
    }

    function setUp() public {
        kf = new KeeperFund(tl, _params());
        game = new OverflowStub();
        address[] memory payers = new address[](1);
        payers[0] = payer;
        kf.wire(payers, address(game));
    }

    // ------------------------------------------------------------------ keeper fund

    function test_tipFormula() public {
        vm.fee(10 gwei);
        // (100k + 40k) × 10 gwei × 1.2 = 0.00168 ETH, + bounty 0.002 × 3h/6h × 20/20 = 0.001
        assertEq(kf.quoteTip(100_000, 3 hours, 20), 0.00168 ether + 0.001 ether);
        // the bounty is per unit of progress: 5 items earn a quarter of it
        assertEq(kf.quoteTip(100_000, 3 hours, 5), 0.00168 ether + 0.00025 ether);
        assertEq(kf.quoteTip(100_000, 3 hours, 0), 0, "no progress, no tip");
        vm.fee(100 gwei); // basefee capped at 30 gwei
        assertEq(kf.quoteTip(100_000, 0, 1), 140_000 * 30 gwei * 12_000 / 10_000);
        assertEq(kf.quoteTip(10_000_000, 7 hours, 50), 0.01 ether + 0.002 ether, "tip cap + full bounty");
    }

    function test_splittingWorkEarnsNoMoreBounty() public {
        vm.fee(0);
        // one call with 20 items after 6 h vs 20 calls of 1 item: the first call takes the age, the rest none
        uint256 one = kf.quoteTip(0, 6 hours, 20);
        uint256 split = kf.quoteTip(0, 6 hours, 1) + 19 * kf.quoteTip(0, 0, 1);
        assertLe(split, one);
    }

    function test_maintenanceFloorOnlyForRetirement() public {
        KeeperFund.Params memory p = _params();
        p.maintenanceFloor = 0.05 ether;
        vm.prank(tl);
        kf.setParams(p);
        vm.deal(address(kf), 0.06 ether);
        vm.fee(10 gwei);
        address keeper = makeAddr("keeper");
        vm.prank(payer);
        assertEq(kf.tip(keeper, 10_000_000, 6 hours, 20, false), 0.01 ether, "down to the floor");
        vm.prank(payer);
        assertEq(kf.tip(keeper, 10_000_000, 6 hours, 20, false), 0, "not below it");
        vm.prank(payer);
        assertGt(kf.tip(keeper, 10_000_000, 6 hours, 20, true), 0, "retirement may spend it");
    }

    function test_tipPaysWhatItCanAndNeverReverts() public {
        vm.fee(10 gwei);
        vm.deal(address(kf), 0.001 ether);
        address keeper = makeAddr("keeper");
        vm.prank(payer);
        assertEq(kf.tip(keeper, 1_000_000, 6 hours, 1, false), 0.001 ether);
        assertEq(keeper.balance, 0.001 ether);
        vm.prank(payer);
        assertEq(kf.tip(keeper, 1_000_000, 6 hours, 1, false), 0);
        vm.expectRevert(KeeperFund.NotPayer.selector);
        kf.tip(keeper, 1, 1, 1, false);
    }

    function test_failedPushIsCredited() public {
        vm.fee(10 gwei);
        vm.deal(address(kf), 1 ether);
        Rejecter r = new Rejecter();
        vm.prank(payer);
        uint256 paid = kf.tip(address(r), 100_000, 0, 1, false);
        assertEq(kf.tipCredit(address(r)), paid);
        assertEq(kf.available(false), 1 ether - paid);
        // the keeper pulls it; Solady's force transfer delivers even to a rejecting receiver
        vm.prank(address(r));
        kf.withdrawTips();
        assertEq(kf.tipCredit(address(r)), 0);
        assertEq(address(r).balance, paid);
        vm.prank(address(r));
        vm.expectRevert(KeeperFund.NothingToWithdraw.selector);
        kf.withdrawTips();
    }

    function test_overflowAboveTargetReturnsToTheGame() public {
        vm.deal(address(this), 1 ether);
        kf.fundKeeper{value: 0.7 ether}();
        assertEq(address(kf).balance, 0.5 ether);
        assertEq(game.returned(), 0.2 ether, "unspent operating allocation goes back to the game");
        vm.expectRevert(Governed.NotGovernance.selector);
        kf.setOverflow(address(game));
    }

    function test_keeperBounds() public {
        KeeperFund.Params memory p = _params();
        vm.startPrank(tl);
        p.tipCap = 0.05 ether + 1;
        vm.expectRevert(Governed.OutOfBounds.selector);
        kf.setParams(p);
        p = _params();
        p.maxBounty = 0.01 ether + 1;
        vm.expectRevert(Governed.OutOfBounds.selector);
        kf.setParams(p);
        p = _params();
        p.rampSeconds = 0;
        vm.expectRevert(Governed.OutOfBounds.selector);
        kf.setParams(p);
        p = _params();
        p.maintenanceFloor = 0.6 ether; // above the target
        vm.expectRevert(Governed.OutOfBounds.selector);
        kf.setParams(p);
        p = _params();
        p.tipCap = 0.05 ether;
        p.maxBounty = 0.01 ether;
        kf.setParams(p);
        vm.stopPrank();
        vm.expectRevert(Governed.NotGovernance.selector);
        kf.setParams(p);
        vm.expectRevert(Governed.NotGovernance.selector);
        kf.setPayer(address(1), true);
    }
}
