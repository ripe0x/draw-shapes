// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Treasury} from "../../src/treasury/Treasury.sol";
import {KeeperFund} from "../../src/treasury/KeeperFund.sol";
import {Governed} from "../../src/Governed.sol";

contract SinkStub {
    Treasury t;

    constructor(Treasury t_) {
        t = t_;
    }

    function take(uint256 a) external {
        t.draw(a);
    }

    receive() external payable {}
}

contract Rejecter {
    receive() external payable {
        revert();
    }
}

contract TreasuryTest is Test {
    address tl = makeAddr("timelock");
    Treasury treasury;
    KeeperFund kf;
    SinkStub a;
    SinkStub b;
    SinkStub c;

    function _params() internal pure returns (KeeperFund.Params memory) {
        return KeeperFund.Params(2_000, 30 gwei, 0.01 ether, 0.002 ether, 6 hours, 40_000, 0.5 ether);
    }

    function setUp() public {
        treasury = new Treasury(tl);
        kf = new KeeperFund(tl, address(treasury), _params());
        a = new SinkStub(treasury);
        b = new SinkStub(treasury);
        c = new SinkStub(treasury);
        address[] memory s = new address[](3);
        uint16[] memory bps = new uint16[](3);
        (s[0], s[1], s[2]) = (address(a), address(b), address(c));
        (bps[0], bps[1], bps[2]) = (4_500, 4_500, 1_000);
        treasury.wire(address(kf), s, bps);
        address[] memory payers = new address[](1);
        payers[0] = address(treasury);
        kf.wire(payers);
    }

    function test_distributeByTableAndDraw() public {
        uint256 amount = 1 ether + 3;
        vm.deal(address(treasury), amount);
        treasury.distribute();
        assertEq(treasury.owed(address(a)), amount * 4_500 / 10_000);
        assertEq(treasury.owed(address(c)), amount - 2 * (amount * 4_500 / 10_000));
        assertEq(treasury.unallocated(), 0);
        vm.expectRevert(Treasury.NoWork.selector);
        treasury.distribute();
        a.take(0.1 ether);
        assertEq(address(a).balance, 0.1 ether);
        vm.expectRevert(Treasury.ExceedsOwed.selector);
        a.take(1 ether);
        vm.expectRevert(Treasury.ExceedsOwed.selector);
        treasury.draw(1); // not a sink
    }

    function test_tableMustSumAndHaveCode() public {
        address[] memory s = new address[](2);
        uint16[] memory bps = new uint16[](2);
        (s[0], s[1]) = (address(a), address(b));
        (bps[0], bps[1]) = (5_000, 4_999);
        vm.startPrank(tl);
        vm.expectRevert(Treasury.InvalidTable.selector);
        treasury.setSinks(s, bps);
        bps[1] = 5_000;
        s[1] = makeAddr("eoa");
        vm.expectRevert(Treasury.InvalidTable.selector);
        treasury.setSinks(s, bps);
        s[1] = address(a);
        vm.expectRevert(Treasury.InvalidTable.selector);
        treasury.setSinks(s, bps); // duplicate
        vm.stopPrank();
        vm.expectRevert(Governed.NotGovernance.selector);
        treasury.setSinks(s, bps);
    }

    function test_newTableReturnsAllocations() public {
        vm.deal(address(treasury), 1 ether);
        treasury.distribute();
        address[] memory s = new address[](1);
        uint16[] memory bps = new uint16[](1);
        (s[0], bps[0]) = (address(b), 10_000);
        vm.prank(tl);
        treasury.setSinks(s, bps);
        assertEq(treasury.owed(address(a)), 0);
        assertEq(treasury.unallocated(), 1 ether);
        treasury.distribute();
        assertEq(treasury.owed(address(b)), 1 ether);
    }

    function testFuzz_tableSumsTo10000(uint16 x, uint16 y) public {
        x = uint16(bound(x, 1, 9_998));
        y = uint16(bound(y, 1, 9_999 - x));
        address[] memory s = new address[](3);
        uint16[] memory bps = new uint16[](3);
        (s[0], s[1], s[2]) = (address(a), address(b), address(c));
        (bps[0], bps[1], bps[2]) = (x, y, 10_000 - x - y);
        vm.prank(tl);
        treasury.setSinks(s, bps);
        uint256 sum;
        for (uint256 i; i < treasury.sinkCount(); ++i) {
            (, uint16 p) = treasury.sinkAt(i);
            sum += p;
        }
        assertEq(sum, 10_000);
    }

    // ------------------------------------------------------------------ keeper fund

    function test_tipFormula() public {
        vm.fee(10 gwei);
        // (100k + 40k) × 10 gwei × 1.2 = 0.00168 ETH, + bounty 0.002 × 3h/6h = 0.001
        assertEq(kf.quoteTip(100_000, 3 hours), 0.00168 ether + 0.001 ether);
        vm.fee(100 gwei); // basefee capped at 30 gwei
        assertEq(kf.quoteTip(100_000, 0), 140_000 * 30 gwei * 12_000 / 10_000);
        assertEq(kf.quoteTip(10_000_000, 7 hours), 0.01 ether + 0.002 ether, "tip cap + full bounty");
    }

    function test_tipPaysWhatItCanAndNeverReverts() public {
        vm.fee(10 gwei);
        vm.deal(address(kf), 0.001 ether);
        address keeper = makeAddr("keeper");
        vm.prank(address(treasury));
        assertEq(kf.tip(keeper, 1_000_000, 6 hours), 0.001 ether);
        assertEq(keeper.balance, 0.001 ether);
        vm.prank(address(treasury));
        assertEq(kf.tip(keeper, 1_000_000, 6 hours), 0);
        vm.expectRevert(KeeperFund.NotPayer.selector);
        kf.tip(keeper, 1, 1);
    }

    function test_failedPushIsCredited() public {
        vm.fee(10 gwei);
        vm.deal(address(kf), 1 ether);
        Rejecter r = new Rejecter();
        vm.prank(address(treasury));
        uint256 paid = kf.tip(address(r), 100_000, 0);
        assertEq(kf.tipCredit(address(r)), paid);
        assertEq(kf.available(), 1 ether - paid);
        // the keeper pulls it; Solady's force transfer delivers even to a rejecting receiver
        vm.prank(address(r));
        kf.withdrawTips();
        assertEq(kf.tipCredit(address(r)), 0);
        assertEq(address(r).balance, paid);
        vm.prank(address(r));
        vm.expectRevert(KeeperFund.NothingToWithdraw.selector);
        kf.withdrawTips();
    }

    function test_overflowAboveTargetGoesToTreasury() public {
        vm.deal(address(this), 1 ether);
        kf.fundKeeper{value: 0.7 ether}();
        assertEq(address(kf).balance, 0.5 ether);
        assertEq(address(treasury).balance, 0.2 ether);
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
