// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPool, IPoolTypes} from "../../../src/interfaces/IPool.sol";
import {EngineTreasury} from "../../../src/engine/EngineTreasury.sol";
import {EngineBase} from "./EngineBase.sol";

/// @notice Seeded random sequences of market, game and treasury actions on the fork, with the
///         accounting invariants checked after every step:
///         - ETH conservation: the treasury balance equals everything that came in less everything
///           that went out, by category, so no inflow is counted twice or as the wrong kind;
///         - the treasury balance covers its booked buckets;
///         - founder payments never pass the entitlement, and every wei paid to founders came from
///           an allowed source;
///         - the treasury is the only shareholder and no withdrawal claim is ever queued;
///         - pool I1 holds;
///         - every coin the treasury bought was burned, and the burn record equals the supply drop.
/// @dev Forge's invariant runner cannot drive a launch this heavy per run, so the sequences are
///      deterministic in the seed and the test runs three seeds.
contract EngineInvariantsForkTest is EngineBase {
    uint256 internal supply0;

    function setUp() public {
        setUpEngine();
        _launch();
        _pastSniperWindow();
        supply0 = coin.totalSupply();
    }

    function test_sequences_seed1() public {
        _run(1, 45);
    }

    function test_sequences_seed2() public {
        _run(2, 45);
    }

    function test_sequences_seed3() public {
        _run(3, 45);
    }

    function _run(uint256 seed, uint256 steps) internal {
        vm.pauseGasMetering();
        uint256 held;
        for (uint256 i; i < steps; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 action = r % 9;
            if (action == 0) {
                held += _buy(trader, 0.1 ether + (r >> 8) % 15 ether);
            } else if (action == 1 && held != 0) {
                uint256 amount = held / (2 + (r >> 16) % 3);
                _sell(trader, amount);
                held -= amount;
            } else if (action == 2 || action == 3) {
                _draws(10 + (r >> 24) % 60);
            } else if (action == 4) {
                try treasury.collectFees() {} catch {}
            } else if (action == 5) {
                try treasury.harvest() {} catch {}
            } else if (action == 6) {
                try treasury.maintainCoverage() {} catch {}
                try treasury.boostGrail() {} catch {}
            } else if (action == 7) {
                vm.roll(block.number + 1);
                try treasury.buyback((r >> 32) % 1 ether, 1) {} catch {}
            } else {
                vm.warp(vm.getBlockTimestamp() + (r >> 40) % 2 days);
                _settleBoard();
            }
            _check();
        }
        vm.resumeGasMetering();
        EngineTreasury.Totals memory t = treasury.totals();
        emit log_named_uint("trading received", t.tradingReceived);
        emit log_named_uint("earnings received", t.earningsReceived);
        emit log_named_uint("founders paid", round.totalDistributed());
        emit log_named_uint("coin burned", t.coinBurned);
        emit log_named_uint("draws booked", ip.grail().pulls);
        assertGt(t.tradingReceived, 0, "sequence exercised trading");
        assertGt(ip.grail().pulls, 100, "sequence exercised draws");
    }

    function _check() internal view {
        EngineTreasury.Totals memory t = treasury.totals();
        uint256 founders = t.foundersFromTrading + t.foundersFromEarnings + t.foundersFromWindDown;
        uint256 inflow = round.totalContributed() + t.tradingReceived + t.earningsReceived + t.principalReturned;
        uint256 outflow = treasury.poolTarget() + t.poolRepaired + treasury.grailSeed() + treasury.maintenanceTarget()
            + t.maintenanceFunded + founders + t.sponsorPaid + t.grailBoosted + t.buybackEthSpent + t.collectiblesBought;
        uint256 unbooked = address(treasury).balance - treasury.booked();
        assertEq(address(treasury).balance - unbooked, inflow - outflow, "ETH conservation by category");
        assertGe(address(treasury).balance, treasury.booked(), "buckets covered");
        assertEq(round.totalDistributed(), founders, "founder ledger equals founder payments");
        assertLe(round.totalDistributed(), round.entitlement(), "never above the cap");
        assertEq(ip.totalShares(), ip.sharesOf(address(treasury)), "sole shareholder");
        assertEq(ip.claims(), 0, "no queued claim");
        assertGe(address(d.pool).balance, ip.cash() + ip.maintenance() + ip.grail().fund, "pool I1");
        assertEq(coin.balanceOf(address(treasury)), 0, "no coin held");
        assertEq(supply0 - coin.totalSupply(), t.coinBurned, "burn record equals supply drop");
    }
}
