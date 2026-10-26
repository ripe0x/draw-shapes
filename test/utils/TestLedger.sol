// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GenesisFarm} from "../../src/token/GenesisFarm.sol";

/// @notice A stand-in game for farm unit tests: units and finality are set directly. (Fork tests use FwaGame.)
contract TestLedger {
    mapping(uint256 => uint256) public epochUnits;
    mapping(uint256 => mapping(address => uint256)) public userUnits;
    mapping(uint256 => bool) public notFinal;

    function add(uint256 epoch, address user, uint256 units) external {
        epochUnits[epoch] += units;
        userUnits[epoch][user] += units;
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
