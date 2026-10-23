// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FoundingRound} from "../../src/engine/FoundingRound.sol";

/// @notice `FoundingRound` alone. It calls no deployed contract, so these run without a fork.
contract FoundingRoundTest is Test {
    FoundingRound internal round;
    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal a = makeAddr("a");
    address internal b = makeAddr("b");

    function setUp() public {
        round = new FoundingRound(owner, treasury, 20 ether, 48 hours, 14 days, 12_000, 0.05 ether);
        vm.deal(a, 100 ether);
        vm.deal(b, 100 ether);
        vm.deal(treasury, 100 ether);
    }

    function _fill() internal {
        vm.prank(a);
        round.contribute{value: 15 ether}();
        vm.prank(b);
        round.contribute{value: 5 ether}();
    }

    function test_hardCapReturnsExcess() public {
        vm.prank(a);
        round.contribute{value: 15 ether}();
        uint256 before = b.balance;
        vm.prank(b);
        round.contribute{value: 9 ether}();
        assertEq(round.contributionOf(b), 5 ether, "accepted the room only");
        assertEq(before - b.balance, 5 ether, "excess returned");
        assertEq(uint256(round.state()), uint256(FoundingRound.State.Funded));
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(FoundingRound.WrongState.selector, FoundingRound.State.Funded));
        round.contribute{value: 1 ether}();
    }

    function test_minimumExceptLastFill() public {
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(FoundingRound.BelowMinimum.selector, 0.05 ether));
        round.contribute{value: 0.01 ether}();
        vm.prank(a);
        round.contribute{value: 20 ether - 0.01 ether}();
        vm.prank(b);
        round.contribute{value: 0.01 ether}();
        assertEq(round.totalContributed(), 20 ether, "small last fill accepted");
    }

    function test_missedTargetRefundsInFull() public {
        vm.prank(a);
        round.contribute{value: 7 ether}();
        vm.warp(round.deadline());
        assertEq(uint256(round.state()), uint256(FoundingRound.State.Refunding));
        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(FoundingRound.WrongState.selector, FoundingRound.State.Refunding));
        round.release();
        uint256 before = a.balance;
        vm.prank(a);
        round.refund();
        assertEq(a.balance - before, 7 ether);
        vm.prank(a);
        vm.expectRevert(FoundingRound.NothingToClaim.selector);
        round.refund();
    }

    function test_fundedButNotLaunchedRefunds() public {
        _fill();
        vm.warp(round.launchDeadline() + 1);
        assertEq(uint256(round.state()), uint256(FoundingRound.State.Refunding), "launch window passed");
        vm.prank(b);
        round.refund();
        assertEq(address(round).balance, 15 ether);
    }

    function test_ownerCancelBeforeRelease() public {
        _fill();
        vm.prank(a);
        vm.expectRevert(FoundingRound.NotOwner.selector);
        round.cancel();
        vm.prank(owner);
        round.cancel();
        vm.prank(a);
        round.refund();
        vm.prank(treasury);
        vm.expectRevert();
        round.release();
    }

    function test_releaseOnlyTreasuryOnlyFunded() public {
        vm.prank(a);
        round.contribute{value: 1 ether}();
        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(FoundingRound.WrongState.selector, FoundingRound.State.Open));
        round.release();
        vm.prank(a);
        round.contribute{value: 19 ether}();
        vm.prank(a);
        vm.expectRevert(FoundingRound.NotTreasury.selector);
        round.release();
        uint256 before = treasury.balance;
        vm.prank(treasury);
        round.release();
        assertEq(treasury.balance - before, 20 ether);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FoundingRound.WrongState.selector, FoundingRound.State.Released));
        round.cancel();
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(FoundingRound.WrongState.selector, FoundingRound.State.Released));
        round.refund();
    }

    function test_distributionsProRataAndCapped() public {
        _fill();
        vm.prank(treasury);
        round.release();
        vm.prank(treasury);
        round.distribute{value: 8 ether}();
        assertEq(round.claimable(a), 6 ether, "75 percent");
        assertEq(round.claimable(b), 2 ether, "25 percent");
        vm.prank(a);
        round.claim();
        assertEq(round.remaining(), 24 ether - 8 ether);
        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(FoundingRound.AboveCap.selector, 16 ether));
        round.distribute{value: 17 ether}();
        vm.prank(treasury);
        round.distribute{value: 16 ether}();
        assertEq(round.remaining(), 0, "cap reached");
        assertEq(round.creditedOf(a), 18 ether, "1.2x of 15");
        assertEq(round.creditedOf(b), 6 ether, "1.2x of 5");
        assertEq(round.claimable(a), 12 ether, "earned and unclaimed survives");
        vm.prank(a);
        round.claim();
        vm.prank(b);
        round.claim();
        assertEq(address(round).balance, 0, "fully paid out");
    }

    function test_distributeOnlyTreasuryAfterRelease() public {
        _fill();
        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(FoundingRound.WrongState.selector, FoundingRound.State.Funded));
        round.distribute{value: 1 ether}();
        vm.prank(treasury);
        round.release();
        vm.prank(a);
        vm.expectRevert(FoundingRound.NotTreasury.selector);
        round.distribute{value: 1 ether}();
    }

    /// @dev Any split of contributions and any sequence of payments: no contributor is ever
    ///      credited more than `capBps` of their contribution, credits sum to at most the payments,
    ///      and the round always holds what it owes.
    function testFuzz_creditsNeverExceedCap(uint96 x, uint96 y, uint256[4] memory pays) public {
        uint256 ca = bound(x, 0.05 ether, 19.95 ether);
        vm.prank(a);
        round.contribute{value: ca}();
        vm.prank(b);
        round.contribute{value: 20 ether - ca + bound(y, 0, 5 ether)}();
        vm.prank(treasury);
        round.release();
        for (uint256 i; i < pays.length; ++i) {
            uint256 room = round.remaining();
            if (room == 0) break;
            uint256 amount = bound(pays[i], 1, room);
            vm.prank(treasury);
            round.distribute{value: amount}();
            if (i == 1 && round.claimable(a) != 0) {
                vm.prank(a);
                round.claim();
            }
        }
        assertLe(round.creditedOf(a), round.contributionOf(a) * 12_000 / 10_000, "a capped");
        assertLe(round.creditedOf(b), round.contributionOf(b) * 12_000 / 10_000, "b capped");
        assertLe(round.creditedOf(a) + round.creditedOf(b), round.totalDistributed(), "no over-credit");
        assertGe(address(round).balance, round.claimable(a) + round.claimable(b), "solvent");
    }
}
