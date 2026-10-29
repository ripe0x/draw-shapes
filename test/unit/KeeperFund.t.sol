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

/// @dev Stands in for the vault: the top-up source.
contract VaultStub {
    uint256 public received;

    receive() external payable {
        received += msg.value;
    }

    function topUp(KeeperFund kf, uint256 amount) external {
        kf.topUp{value: amount}();
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
    VaultStub vault;

    /// @dev The launch values (script/LaunchConfig.sol), floor 0 unless a test sets it.
    function _params() internal pure returns (KeeperFund.Params memory) {
        return KeeperFund.Params({
            tipCap: 0.05 ether,
            maxGasPrice: 5 gwei,
            gasOverhead: 70_000,
            flatFee: 0.0003 ether,
            feeInterval: 1 hours,
            keeperTargetWei: 0.5 ether,
            maintenanceFloor: 0
        });
    }

    function setUp() public {
        vm.warp(10 days);
        kf = new KeeperFund(tl, _params());
        game = new OverflowStub();
        vault = new VaultStub();
        address[] memory payers = new address[](1);
        payers[0] = payer;
        kf.wire(payers, address(game), address(vault));
    }

    function _tip(address keeper, uint256 gas, uint256 work) internal returns (uint256) {
        vm.prank(payer);
        return kf.tip(keeper, gas, work, false);
    }

    // ------------------------------------------------------------------ keeper pay

    /// @notice tip = min(tipCap, (gas + overhead) × min(tx.gasprice, maxGasPrice)) + flatFee once per interval.
    function test_tipFormula() public {
        vm.deal(address(kf), 1 ether);
        address keeper = makeAddr("keeper");
        vm.txGasPrice(2 gwei);
        assertEq(kf.quoteTip(100_000, 1), 170_000 * 2 gwei + 0.0003 ether);
        assertEq(kf.quoteTip(100_000, 0), 0, "no work, no tip");
        // the first useful call of the interval earns the flat fee
        assertEq(_tip(keeper, 100_000, 1), 170_000 * 2 gwei + 0.0003 ether);
        // the next one, within the hour, only its gas
        assertEq(_tip(keeper, 100_000, 1), 170_000 * 2 gwei);
        vm.warp(block.timestamp + 1 hours);
        assertEq(_tip(keeper, 100_000, 1), 170_000 * 2 gwei + 0.0003 ether, "a new interval, a new fee");
        // the gas price is refunded up to maxGasPrice
        vm.txGasPrice(50 gwei);
        assertEq(_tip(keeper, 100_000, 1), 170_000 * 5 gwei);
        // and the gas part up to tipCap
        assertEq(_tip(keeper, 30_000_000, 1), 0.05 ether);
        assertEq(_tip(keeper, 1, 0), 0, "a call that did nothing earns nothing");
    }

    /// @notice Splitting a job into many calls earns no more than one call: gas is refunded at cost, the flat fee is
    ///         paid once an hour.
    function test_splittingWorkEarnsNoMore() public {
        vm.deal(address(kf), 1 ether);
        vm.txGasPrice(1 gwei);
        address a = makeAddr("a");
        uint256 one = _tip(a, 1_000_000, 20);
        vm.warp(block.timestamp + 1 hours);
        uint256 split;
        for (uint256 i; i < 20; ++i) {
            split += _tip(a, 50_000, 1);
        }
        // 20 calls pay 19 more overheads, but no more flat fees: the overhead is the gas a call's own frame costs
        assertEq(split, 20 * (50_000 + 70_000) * 1 gwei + 0.0003 ether);
        assertEq(one, (1_000_000 + 70_000) * 1 gwei + 0.0003 ether);
    }

    function test_maintenanceFloorOnlyForRetirement() public {
        KeeperFund.Params memory p = _params();
        p.maintenanceFloor = 0.05 ether;
        vm.prank(tl);
        kf.setParams(p);
        vm.deal(address(kf), 0.06 ether);
        vm.txGasPrice(5 gwei);
        address keeper = makeAddr("keeper");
        assertEq(_tip(keeper, 10_000_000, 20), 0.01 ether, "down to the floor");
        assertEq(_tip(keeper, 10_000_000, 20), 0, "not below it");
        vm.prank(payer);
        assertGt(kf.tip(keeper, 10_000_000, 20, true), 0, "retirement may spend it");
    }

    function test_tipPaysWhatItCanAndNeverReverts() public {
        vm.txGasPrice(5 gwei);
        vm.deal(address(kf), 0.001 ether);
        address keeper = makeAddr("keeper");
        assertEq(_tip(keeper, 1_000_000, 1), 0.001 ether);
        assertEq(keeper.balance, 0.001 ether);
        assertEq(_tip(keeper, 1_000_000, 1), 0);
        vm.expectRevert(KeeperFund.NotPayer.selector);
        kf.tip(keeper, 1, 1, false);
    }

    function test_failedPushIsCredited() public {
        vm.txGasPrice(5 gwei);
        vm.deal(address(kf), 1 ether);
        Rejecter r = new Rejecter();
        uint256 paid = _tip(address(r), 100_000, 1);
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

    // ------------------------------------------------------------------ funding and overflow

    function test_overflowAboveTargetReturnsToTheGame() public {
        vm.deal(address(this), 1 ether);
        kf.fundKeeper{value: 0.7 ether}();
        assertEq(address(kf).balance, 0.5 ether);
        assertEq(game.returned(), 0.2 ether, "unspent operating allocation goes back to the game");
        vm.expectRevert(Governed.NotGovernance.selector);
        kf.setOverflow(address(game));
    }

    /// @notice The vault's top-ups are capital: the overflow returns them to the vault before anything reaches the
    ///         game, so trading fees never become game profit through the keeper fund.
    function test_overflowReturnsTopUpsToTheVaultFirst() public {
        vm.deal(address(vault), 1 ether);
        vault.topUp(kf, 0.3 ether);
        assertEq(kf.capitalHeld(), 0.3 ether);
        vm.expectRevert(KeeperFund.NotVault.selector);
        kf.topUp{value: 0}();
        vm.deal(address(this), 1 ether);
        kf.fundKeeper{value: 0.4 ether}(); // 0.7 held, 0.2 over the target
        assertEq(vault.received(), 0.2 ether, "the excess goes back to the vault first");
        assertEq(game.returned(), 0);
        assertEq(kf.capitalHeld(), 0.1 ether);
        kf.fundKeeper{value: 0.3 ether}(); // 0.3 over: 0.1 to the vault, 0.2 to the game
        assertEq(vault.received(), 0.3 ether);
        assertEq(game.returned(), 0.2 ether);
        assertEq(kf.capitalHeld(), 0);
    }

    function test_keeperBounds() public {
        KeeperFund.Params memory p = _params();
        vm.startPrank(tl);
        p.tipCap = 0.05 ether + 1;
        vm.expectRevert(Governed.OutOfBounds.selector);
        kf.setParams(p);
        p = _params();
        p.flatFee = 0.005 ether + 1;
        vm.expectRevert(Governed.OutOfBounds.selector);
        kf.setParams(p);
        p = _params();
        p.maxGasPrice = 100 gwei + 1;
        vm.expectRevert(Governed.OutOfBounds.selector);
        kf.setParams(p);
        p = _params();
        p.feeInterval = 1 days + 1;
        vm.expectRevert(Governed.OutOfBounds.selector);
        kf.setParams(p);
        p = _params();
        p.maintenanceFloor = 0.6 ether; // above the target
        vm.expectRevert(Governed.OutOfBounds.selector);
        kf.setParams(p);
        p = _params();
        p.flatFee = 0.005 ether;
        kf.setParams(p);
        vm.stopPrank();
        vm.expectRevert(Governed.NotGovernance.selector);
        kf.setParams(p);
        vm.expectRevert(Governed.NotGovernance.selector);
        kf.setPayer(address(1), true);
    }
}
