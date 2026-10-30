// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {GenesisFarm} from "../../src/token/GenesisFarm.sol";
import {EngineToken} from "../../src/token/EngineToken.sol";
import {EngineRenderer} from "../../src/token/EngineRenderer.sol";
import {Governed} from "../../src/Governed.sol";
import {TestLedger} from "../utils/TestLedger.sol";

contract StubKeeper {
    function tip(address, uint256, uint256, bool) external pure returns (uint256) {
        return 0;
    }
}

/// @notice GenesisFarm: the frozen 14 + 7 schedule, allocation and rate caps, finalization burns, claims.
contract FarmTest is Test {
    uint256 constant GENESIS = 190_000_000 ether;
    uint256 constant BONUS = 10_000_000 ether;
    uint256 constant RATE = 16_000_000 ether; // ENGINE per 1 ETH of ticket ETH in a steady epoch

    address tl = makeAddr("timelock");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    GenesisFarm farm;
    EngineToken engine;
    TestLedger ledger;

    function setUp() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        EngineRenderer r = new EngineRenderer();
        farm = new GenesisFarm(tl, predicted, GENESIS, BONUS, RATE);
        address[] memory to = new address[](2);
        uint256[] memory amt = new uint256[](2);
        (to[0], amt[0]) = (address(farm), GENESIS + BONUS);
        (to[1], amt[1]) = (address(0xFA), 800_000_000 ether);
        engine = new EngineToken(tl, to, amt, address(r));
        assertEq(address(engine), predicted);
        ledger = new TestLedger();
        farm.wire(address(ledger), address(ledger), address(new StubKeeper()));
    }

    function _open() internal {
        vm.roll(1000);
        ledger.start(farm);
    }

    function _toEpoch(uint256 e) internal {
        vm.roll(farm.openBlock() + e * 7_200);
    }

    function _one(uint256 e) internal pure returns (uint256[] memory es) {
        es = new uint256[](1);
        es[0] = e;
    }

    function _claim(address who, uint256 e) internal returns (uint256) {
        vm.prank(who);
        return farm.claim(_one(e));
    }

    function test_scheduleIsFourteenSteadyThenSevenTaperSteps() public view {
        uint256 steady = GENESIS * 8 / 140;
        assertEq(steady, GENESIS * 10 / 175, "F / 17.5");
        uint256 sum;
        for (uint256 e; e < 21; ++e) {
            uint256 cap = farm.allocationCap(e);
            sum += cap;
            if (e < 14) {
                assertEq(cap, steady);
                assertEq(farm.rateCapOf(e), RATE);
            } else if (e < 20) {
                // 87.5%, 75%, ..., 12.5% of a steady epoch, applied to both caps
                assertEq(cap, GENESIS * (21 - e) / 140);
                assertEq(farm.rateCapOf(e), RATE * (21 - e) / 8);
            }
        }
        assertEq(farm.allocationCap(20) * 1e3 / steady, 125, "the last epoch is 12.5%");
        assertEq(sum, GENESIS, "the caps sum to the budget exactly");
        assertEq(farm.allocationCap(21), 0);
        assertEq(farm.rateCapOf(21), 0);
    }

    function testFuzz_capsSumForAnyBudget(uint128 budget) public {
        GenesisFarm f = new GenesisFarm(tl, address(engine), budget, 0, RATE);
        uint256 sum;
        for (uint256 e; e < 21; ++e) {
            sum += f.allocationCap(e);
        }
        assertEq(sum, budget);
    }

    function test_clockFixedEnd() public {
        assertEq(farm.genesisEndBlock(), type(uint256).max);
        vm.expectRevert(GenesisFarm.NotLedger.selector);
        farm.start();
        _open();
        assertEq(farm.openBlock(), 1000);
        assertEq(farm.genesisEndBlock(), 1000 + 21 * 7_200);
        vm.expectRevert(GenesisFarm.AlreadyStarted.selector);
        ledger.start(farm);
        // nothing can move the end: there is no shorten or extend
        (bool ok,) = address(farm).call(abi.encodeWithSignature("shorten(uint256)", 7));
        assertFalse(ok);
        _toEpoch(20);
        assertEq(farm.currentEpoch(), 20);
    }

    function test_rateCapBindsSmallActivity() public {
        _open();
        // one 0.03 ETH ticket: it earns its rate, never the whole pot
        ledger.add(0, alice, 0.03 ether);
        _toEpoch(1);
        assertEq(farm.potOf(0), 0.03 ether * RATE / 1 ether);
        assertLt(farm.potOf(0), farm.allocationCap(0) / 20, "a small purchase takes a small part");
        uint256 cap = farm.allocationCap(0);
        uint256 got = _claim(alice, 0);
        assertEq(got, 0.03 ether * RATE / 1 ether);
        // the rest of the cap is conclusively unearned: burned at finalization
        assertEq(farm.totalBurned(), cap - got);
    }

    function test_allocationCapBindsHighActivity() public {
        _open();
        ledger.add(0, alice, 3 ether);
        ledger.add(0, bob, 1 ether);
        _toEpoch(1);
        // 4 ETH × 16M = 64M ENGINE > the 10.857M cap: the cap binds, split pro rata by ticket ETH
        assertEq(farm.potOf(0), farm.allocationCap(0));
        uint256 a = _claim(alice, 0);
        uint256 b = _claim(bob, 0);
        assertEq(a, farm.allocationCap(0) * 3 / 4);
        assertEq(b, farm.allocationCap(0) / 4);
        assertEq(farm.totalBurned(), 0, "nothing unearned");
    }

    function test_taperEpochsApplyBothCaps() public {
        _open();
        ledger.add(17, alice, 0.1 ether);
        ledger.add(18, alice, 100 ether);
        _toEpoch(19);
        assertEq(farm.potOf(17), 0.1 ether * (RATE * 4 / 8) / 1 ether, "rate cap at 50%");
        assertEq(farm.potOf(18), GENESIS * 3 / 140, "allocation cap at 37.5%");
    }

    function test_zeroParticipationBurnsTheWholeCap() public {
        _open();
        _toEpoch(1);
        assertEq(farm.potOf(0), 0);
        farm.finalize(_one(0));
        assertEq(farm.totalBurned(), farm.allocationCap(0));
        vm.expectRevert(GenesisFarm.NoWork.selector);
        farm.finalize(_one(0));
        vm.expectRevert(GenesisFarm.NothingToClaim.selector);
        _claim(alice, 0);
    }

    function test_claimsWaitForFinalityAndNeverExpire() public {
        _open();
        ledger.add(0, alice, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(GenesisFarm.NotFinal.selector, 0));
        _claim(alice, 0);
        _toEpoch(1);
        ledger.setNotFinal(0, true); // a request still open in the game
        vm.expectRevert(abi.encodeWithSelector(GenesisFarm.NotFinal.selector, 0));
        _claim(alice, 0);
        vm.expectRevert(abi.encodeWithSelector(GenesisFarm.NotFinal.selector, 0));
        farm.finalize(_one(0));
        // an unrelated epoch finalizes and pays meanwhile
        ledger.add(1, bob, 1 ether);
        _toEpoch(2);
        assertGt(_claim(bob, 1), 0, "a stuck epoch does not block another");
        ledger.setNotFinal(0, false);
        // years later the claim is still there
        vm.roll(block.number + 10_000_000);
        uint256 got = _claim(alice, 0);
        assertEq(got, farm.potOf(0));
        vm.expectRevert(abi.encodeWithSelector(GenesisFarm.AlreadyClaimed.selector, 0));
        _claim(alice, 0);
    }

    function test_finalizedPotNeverChanges() public {
        _open();
        ledger.add(0, alice, 0.5 ether);
        _toEpoch(1);
        farm.finalize(_one(0));
        uint256 pot = farm.potOf(0);
        // a late write to the ledger (it cannot happen with FwaGame, whose final epochs are frozen) changes nothing
        ledger.add(0, bob, 0.5 ether);
        assertEq(farm.potOf(0), pot);
    }

    function test_cleanupKeepsEarnedAndPotentiallyEarnedRewards() public {
        _open();
        ledger.add(0, alice, 1 ether);
        ledger.add(5, bob, 0.2 ether);
        _toEpoch(21);
        ledger.setNotFinal(5, true); // potentially earned: not final yet
        // the bonus pool retires at the end; genesis pots are untouched
        farm.retireBonus();
        assertEq(farm.bonusPool(), 0);
        // finalize what is final; epoch 5 stays reserved in full
        uint256[] memory es = new uint256[](21);
        uint256 n;
        for (uint256 e; e < 21; ++e) {
            if (e != 5) es[n++] = e;
        }
        assembly {
            mstore(es, n)
        }
        farm.finalize(es);
        assertEq(farm.reserved(), farm.potOf(0) + farm.allocationCap(5), "earned plus potentially earned");
        assertGe(engine.balanceOf(address(farm)), farm.reserved());
        ledger.setNotFinal(5, false);
        assertEq(_claim(bob, 5), 0.2 ether * RATE / 1 ether);
        assertEq(_claim(alice, 0), farm.allocationCap(0), "alice's epoch hit the cap");
        assertEq(farm.reserved(), 0);
        assertLe(engine.balanceOf(address(farm)), 21, "only rounding dust left");
    }

    function test_bonusFromConverterOnlyAndRetiresAfterGenesis() public {
        vm.expectRevert(GenesisFarm.NotBonusPayer.selector);
        farm.payBonus(alice, 1);
        assertEq(ledger.bonus(farm, alice, 5 ether), 5 ether);
        assertEq(engine.balanceOf(alice), 5 ether);
        vm.expectRevert(GenesisFarm.GenesisNotOver.selector);
        farm.retireBonus();
        _open();
        _toEpoch(20);
        vm.expectRevert(GenesisFarm.GenesisNotOver.selector);
        farm.retireBonus();
        _toEpoch(21);
        uint256 left = farm.bonusPool();
        assertEq(farm.retireBonus(), left);
        assertEq(farm.totalBurned(), left);
        // conversion keeps working, without a bonus
        assertEq(ledger.bonus(farm, alice, 1 ether), 0);
        vm.expectRevert(GenesisFarm.NoWork.selector);
        farm.retireBonus();
    }

    function test_multipleLedgersSumWeight() public {
        TestLedger second = new TestLedger();
        vm.prank(tl);
        farm.addLedger(address(second));
        _open();
        ledger.add(0, alice, 0.1 ether);
        second.add(0, alice, 0.1 ether);
        second.add(0, bob, 0.2 ether);
        _toEpoch(1);
        assertEq(farm.epochWeight(0), 0.4 ether);
        assertEq(farm.rewardOf(0, alice), farm.potOf(0) / 2);
        second.setNotFinal(0, true);
        assertFalse(farm.isFinal(0));
    }

    /// @notice A ledger governance adds later counts only from the epoch it was added in, so it cannot dilute a
    ///         finalized epoch by reporting historical weight (audit finding 5).
    function test_lateLedgerCannotDiluteFinalizedEpochs() public {
        _open();
        ledger.add(0, alice, 1 ether);
        _toEpoch(1);
        farm.finalize(_one(0));
        uint256 pot = farm.potOf(0);
        // governance registers a ledger that reports the same historical weight for bob
        TestLedger late = new TestLedger();
        late.add(0, bob, 1 ether);
        late.add(1, bob, 1 ether);
        vm.prank(tl);
        farm.addLedger(address(late));
        assertEq(farm.ledgerFrom(address(late)), 1);
        assertEq(farm.epochWeight(0), 1 ether, "epoch 0 ignores the late ledger");
        assertEq(farm.rewardOf(0, bob), 0);
        assertEq(_claim(alice, 0), pot, "alice keeps the whole finalized pot");
        // from its first epoch on the late ledger counts
        assertEq(farm.epochWeight(1), 1 ether);
        assertEq(farm.userWeight(1, bob), 1 ether);
    }

    function test_settersAccess() public {
        vm.expectRevert(Governed.NotGovernance.selector);
        farm.addLedger(address(1));
        vm.expectRevert(Governed.NotGovernance.selector);
        farm.setBonusPayer(address(1), true);
        vm.expectRevert(Governed.NotGovernance.selector);
        farm.setKeeperFund(address(1));
        vm.expectRevert(Governed.NotDeployer.selector);
        farm.wire(address(1), address(1), address(1));
    }
}
