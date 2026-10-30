// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GenesisFarm} from "../../src/token/GenesisFarm.sol";

/// @notice A stand-in game for farm unit tests: weights (ticket ETH) and finality are set directly. (Fork tests use
///         FwaGame.)
contract TestLedger {
    mapping(uint256 => uint256) public epochWeight;
    mapping(uint256 => mapping(address => uint256)) public userWeight;
    mapping(uint256 => bool) public notFinal;

    function add(uint256 epoch, address user, uint256 weight) external {
        epochWeight[epoch] += weight;
        userWeight[epoch][user] += weight;
    }

    function setNotFinal(uint256 epoch, bool v) external {
        notFinal[epoch] = v;
    }

    function isEpochFinal(uint256 epoch) external view returns (bool) {
        return !notFinal[epoch];
    }

    function start(GenesisFarm farm) external {
        farm.start();
    }

    function bonus(GenesisFarm farm, address to, uint256 amount) external returns (uint256) {
        return farm.payBonus(to, amount);
    }
}
