// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {GenesisFarm} from "../../src/token/GenesisFarm.sol";
import {EngineToken} from "../../src/token/EngineToken.sol";
import {EngineRenderer} from "../../src/token/EngineRenderer.sol";
import {EmissionSchedule} from "../../src/policy/EmissionSchedule.sol";
import {Governed} from "../../src/Governed.sol";
import {TestLedger} from "../utils/TestLedger.sol";

contract FarmTest is Test {
    uint256 constant GENESIS = 100_000_000 ether;
    uint256 constant BONUS = 10_000_000 ether;
    uint256 constant RESERVE = 790_000_000 ether;

    address tl = makeAddr("timelock");
    address depositor = makeAddr("depositor");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    GenesisFarm farm;
    EngineToken engine;
    EmissionSchedule schedule;
    TestLedger ledger;

    function setUp() public {
        schedule = new EmissionSchedule();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        EngineRenderer r = new EngineRenderer();
        farm = new GenesisFarm(tl, predicted, GENESIS, BONUS, RESERVE, address(schedule));
        address[] memory to = new address[](2);
        uint256[] memory amt = new uint256[](2);
        (to[0], amt[0]) = (address(farm), GENESIS + BONUS + RESERVE);
        (to[1], amt[1]) = (depositor, 100_000_000 ether);
        engine = new EngineToken(tl, to, amt, address(r));
        assertEq(address(engine), predicted);
        ledger = new TestLedger();
        farm.wire(address(ledger), depositor, address(ledger), address(new StubKeeper()));
        vm.prank(depositor);
        engine.approve(address(farm), type(uint256).max);
    }

    function _open() internal {
        vm.roll(1000);
        ledger.start(farm);
    }

    function _toEpoch(uint256 e) internal {
        vm.roll(farm.openBlock() + e * 7_200);
    }

    function _claim(address who, uint256 e) internal returns (uint256) {
        uint256[] memory es = new uint256[](1);
        es[0] = e;
        vm.prank(who);
        return farm.claim(es);
    }

    function test_taperSumsToAllocation() public view {
        uint256 sum;
        for (uint256 e; e < 21; ++e) {
            sum += schedule.allocationOf(e, GENESIS);
        }
        assertEq(sum, GENESIS);
        uint256 avg = GENESIS / 21;
        assertApproxEqRel(schedule.allocationOf(0, GENESIS), avg * 3 / 2, 1e12);
        assertApproxEqRel(schedule.allocationOf(20, GENESIS), avg / 2, 1e12);
        assertEq(schedule.allocationOf(21, GENESIS), 0);
        // monotonic taper
        for (uint256 e = 1; e < 20; ++e) {
            assertLt(schedule.allocationOf(e, GENESIS), schedule.allocationOf(e - 1, GENESIS));
        }
    }

    function testFuzz_taperSumsForAnyTotal(uint128 total) public view {
        uint256 sum;
        for (uint256 e; e < 21; ++e) {
            sum += schedule.allocationOf(e, total);
        }
        assertEq(sum, total);
    }

    function test_clockAndStart() public {
        assertEq(farm.genesisEndBlock(), type(uint256).max);
        vm.expectRevert(GenesisFarm.NotLedger.selector);
        farm.start();
        _open();
        assertEq(farm.openBlock(), 1000);
        assertEq(farm.genesisEndBlock(), 1000 + 21 * 7_200);
        vm.expectRevert(GenesisFarm.AlreadyStarted.selector);
        ledger.start(farm);
        _toEpoch(3);
        assertEq(farm.currentEpoch(), 3);
    }

    function test_claimProRataOnceFinal() public {
        _open();
        ledger.add(0, alice, 3);
        ledger.add(0, bob, 1);
        vm.expectRevert(abi.encodeWithSelector(GenesisFarm.NotFinal.selector, 0));
        _claim(alice, 0);
        _toEpoch(1);
        uint256 pot = schedule.allocationOf(0, GENESIS);
        assertEq(_claim(alice, 0), pot * 3 / 4);
        assertEq(_claim(bob, 0), pot / 4);
        assertEq(engine.balanceOf(alice), pot * 3 / 4);
        vm.expectRevert(abi.encodeWithSelector(GenesisFarm.AlreadyClaimed.selector, 0));
        _claim(alice, 0);
    }

    function test_finalityWaitsForLedger() public {
        _open();
        ledger.add(0, alice, 1);
        ledger.setNotFinal(0, true);
        _toEpoch(5);
        assertFalse(farm.isFinal(0));
        vm.expectRevert(abi.encodeWithSelector(GenesisFarm.NotFinal.selector, 0));
        _claim(alice, 0);
        ledger.setNotFinal(0, false);
        assertGt(_claim(alice, 0), 0);
    }

    function test_depositsGoToCurrentEpochAndPostGenesisPots() public {
        _open();
        _toEpoch(25); // past genesis
        vm.prank(depositor);
        farm.deposit(1_000 ether);
        assertEq(farm.deposits(25), 1_000 ether);
        assertEq(farm.potOf(25), 1_000 ether, "post-genesis pot is deposits only");
        ledger.add(25, alice, 2);
        _toEpoch(26);
        assertEq(_claim(alice, 25), 1_000 ether);
        vm.expectRevert(GenesisFarm.NotDepositor.selector);
        farm.deposit(1);
    }

    function test_rolloverOfEmptyEpoch() public {
        _open();
        _toEpoch(22);
        vm.prank(depositor);
        farm.deposit(500 ether);
        _toEpoch(24);
        farm.rollover(22);
        assertEq(farm.rolledIn(24), 500 ether);
        assertEq(farm.potOf(22), 0);
        vm.expectRevert(abi.encodeWithSelector(GenesisFarm.CannotRollover.selector, 22));
        farm.rollover(22);
        ledger.add(24, bob, 1);
        _toEpoch(25);
        assertEq(_claim(bob, 24), 500 ether);
    }

    function test_rolloverRejectsEpochWithUnits() public {
        _open();
        ledger.add(22, alice, 1);
        _toEpoch(24);
        vm.expectRevert(abi.encodeWithSelector(GenesisFarm.CannotRollover.selector, 22));
        farm.rollover(22);
    }

    function test_shortenBurnsCutEpochsWithNotice() public {
        _open();
        _toEpoch(3);
        vm.expectRevert(Governed.NotGovernance.selector);
        farm.shorten(10);
        vm.startPrank(tl);
        vm.expectRevert(GenesisFarm.InvalidShorten.selector);
        farm.shorten(5); // below 7 and below notice
        vm.expectRevert(GenesisFarm.InvalidShorten.selector);
        farm.shorten(21); // not shorter
        uint256 cut;
        for (uint256 e = 10; e < 21; ++e) {
            cut += schedule.allocationOf(e, GENESIS);
        }
        uint256 supply = engine.totalSupply();
        farm.shorten(10);
        vm.stopPrank();
        assertEq(farm.genesisEpochs(), 10);
        assertEq(engine.totalSupply(), supply - cut);
        assertEq(farm.genesisEndBlock(), farm.openBlock() + 10 * 7_200);
        assertEq(farm.potOf(12), 0);
        // notice: at epoch 7, the soonest end is 10 (current + 1 + 2)
        _toEpoch(8);
        vm.prank(tl);
        vm.expectRevert(GenesisFarm.InvalidShorten.selector);
        farm.shorten(9);
    }

    function test_retireUnearnedBurnsEmptyGenesisEpochsAndBonus() public {
        _open();
        ledger.add(0, alice, 1);
        ledger.add(5, alice, 1);
        vm.expectRevert(GenesisFarm.GenesisNotOver.selector);
        farm.retireUnearned();
        _toEpoch(21);
        uint256 empty = GENESIS - schedule.allocationOf(0, GENESIS) - schedule.allocationOf(5, GENESIS);
        uint256 supply = engine.totalSupply();
        uint256 burned = farm.retireUnearned();
        assertEq(burned, empty);
        assertEq(engine.totalSupply(), supply - empty - BONUS);
        assertEq(farm.bonusPool(), 0);
        // earned rewards stay claimable
        assertEq(_claim(alice, 0), schedule.allocationOf(0, GENESIS));
        assertEq(_claim(alice, 5), schedule.allocationOf(5, GENESIS));
        assertEq(engine.balanceOf(address(farm)), RESERVE);
        vm.expectRevert(GenesisFarm.AlreadyRetired.selector);
        farm.retireUnearned();
    }

    function test_bonusFromLedgerOnly() public {
        vm.expectRevert(GenesisFarm.NotBonusPayer.selector);
        farm.payBonus(alice, 1);
        assertEq(ledger.bonus(farm, alice, 5 ether), 5 ether);
        assertEq(engine.balanceOf(alice), 5 ether);
        assertEq(farm.bonusPool(), BONUS - 5 ether);
        assertEq(ledger.bonus(farm, alice, BONUS), BONUS - 5 ether, "pays what is left");
        assertEq(ledger.bonus(farm, alice, 1), 0);
    }

    function test_seasonsFromReserveOnlyWithLimits() public {
        _open();
        uint256 avg = GENESIS / 21;
        vm.startPrank(tl);
        vm.expectRevert(GenesisFarm.InvalidSeason.selector);
        farm.scheduleSeason(10, 10, 1_000 ether); // inside genesis
        vm.stopPrank();
        _toEpoch(20);
        vm.startPrank(tl);
        vm.expectRevert(GenesisFarm.InvalidSeason.selector);
        farm.scheduleSeason(26, 10, 1_000 ether); // less than 7 epochs of notice
        vm.expectRevert(GenesisFarm.InvalidSeason.selector);
        farm.scheduleSeason(30, 2, 2 * avg + 2); // more than the genesis average per epoch
        vm.expectRevert(GenesisFarm.ExceedsReserve.selector);
        farm.scheduleSeason(30, 10, RESERVE + 1);
        farm.scheduleSeason(30, 10, 1_000 ether);
        vm.expectRevert(GenesisFarm.InvalidSeason.selector);
        farm.scheduleSeason(35, 10, 1_000 ether); // overlaps
        farm.scheduleSeason(40, 10, 1_000 ether); // adjacent is fine
        vm.stopPrank();
        assertEq(farm.reserve(), RESERVE - 2_000 ether);
        assertEq(farm.seasonAllocationOf(30), 100 ether);
        assertEq(farm.seasonAllocationOf(45), 100 ether);
        assertEq(farm.seasonAllocationOf(50), 0);
        ledger.add(31, bob, 1);
        _toEpoch(32);
        assertEq(_claim(bob, 31), 100 ether);
        uint256 supply = engine.totalSupply();
        vm.prank(tl);
        farm.burnReserve(1 ether);
        assertEq(engine.totalSupply(), supply - 1 ether);
        vm.expectRevert(Governed.NotGovernance.selector);
        farm.burnReserve(1);
    }

    function test_finalEpochClaimsNeverChange() public {
        _open();
        ledger.add(0, alice, 1);
        ledger.add(0, bob, 1);
        _toEpoch(1);
        uint256 before = farm.rewardOf(0, bob);
        // nothing that can happen after finality moves a final epoch's pot: deposits land in the current epoch
        vm.prank(depositor);
        farm.deposit(1_000 ether);
        uint256 a = _claim(alice, 0);
        assertEq(farm.rewardOf(0, bob), before);
        assertEq(_claim(bob, 0), a);
    }

    function test_genesisCommitmentCapsBadSchedule() public {
        // a farm built with a schedule that over-allocates still pays at most the genesis budget
        DoubleSchedule d = new DoubleSchedule();
        EngineRenderer r = new EngineRenderer();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        GenesisFarm f2 = new GenesisFarm(tl, predicted, GENESIS, BONUS, RESERVE, address(d));
        address[] memory to = new address[](1);
        uint256[] memory amt = new uint256[](1);
        (to[0], amt[0]) = (address(f2), 1_000_000_000 ether);
        EngineToken t2 = new EngineToken(tl, to, amt, address(r));
        assertEq(address(t2), predicted);
        TestLedger l2 = new TestLedger();
        f2.wire(address(l2), depositor, address(l2), address(new StubKeeper()));
        vm.roll(1000);
        l2.start(f2);
        for (uint256 e; e < 21; ++e) {
            l2.add(e, alice, 1);
        }
        vm.roll(f2.openBlock() + 21 * 7_200);
        uint256 total;
        uint256[] memory es = new uint256[](1);
        for (uint256 e; e < 21; ++e) {
            if (f2.potOf(e) == 0) break;
            es[0] = e;
            vm.prank(alice);
            total += f2.claim(es);
        }
        assertLe(total, GENESIS, "never more than the genesis budget");
    }

    function test_settersAccess() public {
        vm.expectRevert(Governed.NotGovernance.selector);
        farm.addLedger(address(1));
        vm.expectRevert(Governed.NotGovernance.selector);
        farm.setDepositor(address(1), true);
        vm.expectRevert(Governed.NotGovernance.selector);
        farm.scheduleSeason(30, 1, 1);
        vm.expectRevert(Governed.NotDeployer.selector);
        farm.wire(address(1), address(1), address(1), address(1));
        vm.startPrank(tl);
        farm.addLedger(address(new TestLedger()));
        farm.addLedger(address(new TestLedger()));
        farm.addLedger(address(new TestLedger()));
        address fifth = address(new TestLedger());
        vm.expectRevert(Governed.OutOfBounds.selector);
        farm.addLedger(fifth);
        vm.stopPrank();
    }

    function test_multipleLedgersSumUnits() public {
        TestLedger l2 = new TestLedger();
        vm.prank(tl);
        farm.addLedger(address(l2));
        _open();
        ledger.add(0, alice, 1);
        l2.add(0, bob, 1);
        assertEq(farm.epochUnits(0), 2);
        l2.setNotFinal(0, true);
        _toEpoch(1);
        assertFalse(farm.isFinal(0));
        l2.setNotFinal(0, false);
        uint256 pot = schedule.allocationOf(0, GENESIS);
        assertEq(_claim(bob, 0), pot / 2);
    }
}

contract DoubleSchedule {
    function allocationOf(uint256 epoch, uint256 total) external pure returns (uint256) {
        return epoch < 21 ? total * 2 / 21 : 0;
    }
}

contract StubKeeper {
    function tip(address, uint256, uint256, uint256, bool) external pure returns (uint256) {
        return 0;
    }
}
