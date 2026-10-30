// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";

contract SmokeTest is ForkBase {
    function setUp() public {
        deployLaunch();
    }

    function test_smoke() public {
        fundAndFill(OPENING_CAPITAL);
        emit log_named_uint("live", sys.game.liveCount());
        emit log_named_uint("cash", sys.game.cash());
        openMarket();
        openGame();
        address alice = makeAddr("alice");
        uint256 id = pullAndSettle(alice, 12345);
        emit log_named_uint("status", uint8(statusOf(id)));
        vm.warp(block.timestamp + 1 hours);
        sys.game.sync(10);
        emit log_named_uint("pulls", sys.game.pullsBooked());
        emit log_named_int("profit", sys.game.profit());
        emit log_named_uint("buyback", address(sys.buyback).balance);
        emit log_named_uint("keeper", address(sys.keeperFund).balance);
    }
}
