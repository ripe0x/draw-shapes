// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BoardPolicy, PricingPolicy, GrailPolicy} from "../../src/policy/GamePolicies.sol";
import {SwapPolicy} from "../../src/policy/SwapPolicy.sol";
import {PrizeVault} from "../../src/game/PrizeVault.sol";
import {EngineToken} from "../../src/token/EngineToken.sol";
import {EngineRenderer} from "../../src/token/EngineRenderer.sol";
import {Governed} from "../../src/Governed.sol";

contract ClockStub {
    uint256 public openBlock;
    uint256 public genesisEndBlock = type(uint256).max;

    function set(uint256 o, uint256 e) external {
        openBlock = o;
        genesisEndBlock = e;
    }
}

contract HookStub {
    uint64 public launchedAt;

    function set(uint64 t) external {
        launchedAt = t;
    }
}

contract GameStub {
    PrizeVault v;
    bool public retireCalled;

    constructor(PrizeVault v_) {
        v = v_;
    }

    function receiveFunding() external payable {}

    function retire() external {
        retireCalled = true;
    }

    function giveBack(bool f) external {
        v.repay{value: address(this).balance}(f);
    }
}

contract ModulesTest is Test {
    address tl = makeAddr("timelock");

    function test_boardBounds() public {
        uint8[] memory k = new uint8[](201);
        uint96[] memory b = new uint96[](201);
        vm.expectRevert(Governed.OutOfBounds.selector);
        new BoardPolicy(tl, k, b, 20);
        k = new uint8[](2);
        b = new uint96[](2);
        b[0] = 0.01 ether;
        b[1] = 0.05 ether;
        vm.expectRevert(Governed.OutOfBounds.selector);
        new BoardPolicy(tl, k, b, 21);
        k[1] = 2;
        vm.expectRevert(Governed.OutOfBounds.selector);
        new BoardPolicy(tl, k, b, 20);
        k[1] = 1;
        BoardPolicy p = new BoardPolicy(tl, k, b, 10);
        assertEq(p.rowCount(), 2);
        (uint8 kind, uint96 backing) = p.rowAt(1);
        assertEq(kind, 1);
        assertEq(backing, 0.05 ether);
        vm.expectRevert(Governed.NotGovernance.selector);
        p.setBoard(k, b, 10);
    }

    function test_pricingBounds() public {
        PricingPolicy p = new PricingPolicy(tl, 300, 200);
        assertEq(p.listPrice(0, 0.01 ether, 0.011 ether), 0.01133 ether);
        vm.startPrank(tl);
        vm.expectRevert(Governed.OutOfBounds.selector);
        p.set(501, 200);
        vm.expectRevert(Governed.OutOfBounds.selector);
        p.set(300, 501);
        p.set(500, 500);
        vm.stopPrank();
        vm.expectRevert(Governed.NotGovernance.selector);
        p.set(0, 0);
    }

    function test_grailPolicyDecay() public {
        uint256[] memory ladder = new uint256[](3);
        (ladder[0], ladder[1], ladder[2]) = (0.5 ether, 1 ether, 5 ether);
        GrailPolicy g = new GrailPolicy(tl, ladder, 9_500, 8_000, 100, 100);
        assertEq(g.grailBacking(0), 0.5 ether);
        assertEq(g.grailBacking(7), 5 ether, "last rung repeats");
        assertEq(g.grailPrice(1 ether, 0), 0.95 ether);
        assertEq(g.grailPrice(1 ether, 250), 0.93 ether);
        assertEq(g.grailPrice(1 ether, 100_000), 0.8 ether, "floor");
        vm.expectRevert(Governed.NotGovernance.selector);
        g.set(ladder, 1, 1, 1, 1);
    }

    function test_swapPolicyGateExemptSnipe() public {
        ClockStub clock = new ClockStub();
        HookStub hook = new HookStub();
        SwapPolicy p = new SwapPolicy(tl, address(clock), 300, 5_000, 1 hours);
        address[] memory ex = new address[](1);
        ex[0] = address(0xB0B);
        p.wire(address(hook), ex);
        (bool ok, uint256 fee) = p.check(address(1), true);
        assertTrue(ok);
        assertEq(fee, 300, "no launch yet");
        hook.set(uint64(block.timestamp));
        (, fee) = p.check(address(1), true);
        assertEq(fee, 5_300);
        (, fee) = p.check(address(1), false);
        assertEq(fee, 300, "sells pay no snipe fee");
        clock.set(block.number, block.number + 100);
        (ok,) = p.check(address(1), true);
        assertFalse(ok, "gated");
        (ok, fee) = p.check(address(1), false);
        assertTrue(ok, "sells pass the gate");
        (ok, fee) = p.check(address(0xB0B), true);
        assertTrue(ok);
        assertEq(fee, 0);
        vm.roll(block.number + 100);
        (ok,) = p.check(address(1), true);
        assertTrue(ok, "gate ends at genesis end");
        vm.startPrank(tl);
        vm.expectRevert(Governed.OutOfBounds.selector);
        p.setFee(501);
        vm.expectRevert(Governed.OutOfBounds.selector);
        p.setSnipe(9_001, 1 hours);
        vm.expectRevert(Governed.OutOfBounds.selector);
        p.setSnipe(5_000, 3 hours + 1);
        p.setSnipe(0, 0);
        vm.stopPrank();
    }

    function test_vaultFundRetireRepay() public {
        address lp = makeAddr("lp");
        PrizeVault v = new PrizeVault(tl, lp, 30 days);
        GameStub g = new GameStub(v);
        v.wire(address(g));
        vm.deal(address(v), 5 ether);
        v.fund();
        assertEq(address(g).balance, 5 ether);
        vm.expectRevert(PrizeVault.NothingToSend.selector);
        v.fund();
        vm.expectRevert(PrizeVault.NotGame.selector);
        v.repay(true);
        vm.expectRevert(Governed.NotGovernance.selector);
        v.retireGame();
        vm.prank(tl);
        v.retireGame();
        assertTrue(g.retireCalled());
        vm.expectRevert(PrizeVault.NoActiveGame.selector);
        v.fund();
        g.giveBack(true);
        assertEq(v.activeGame(), address(0));
        assertEq(address(v).balance, 5 ether);
        vm.expectRevert(PrizeVault.NotReady.selector);
        v.shutdown(0);
        vm.prank(tl);
        vm.expectRevert(Governed.OutOfBounds.selector);
        v.setShutdownDelay(1 hours);
    }

    function test_tokenSupplyMetadataPermit() public {
        EngineRenderer r = new EngineRenderer();
        address[] memory to = new address[](2);
        uint256[] memory amt = new uint256[](2);
        (to[0], amt[0]) = (address(this), 100_000_000 ether);
        (to[1], amt[1]) = (address(0xFA), 900_000_000 ether);
        EngineToken t = new EngineToken(tl, to, amt, address(r));
        assertEq(t.totalSupply(), 1_000_000_000 ether);
        assertEq(t.name(), "ENGINE");
        assertEq(t.symbol(), "ENGINE");
        assertEq(t.decimals(), 18);
        t.burn(10_000_000 ether);
        assertEq(t.totalSupply(), 990_000_000 ether);
        string memory uri = t.contractURI();
        assertEq(bytes(uri).length > 100, true);
        assertEq(keccak256(bytes(t.tokenURI())), keccak256(bytes(uri)));
        vm.expectRevert(Governed.NotGovernance.selector);
        t.setRenderer(address(r));
        vm.prank(tl);
        vm.expectRevert(EngineToken.InvalidRenderer.selector);
        t.setRenderer(address(0x1234));
        // supply must be exactly 1B
        amt[1] = 1;
        vm.expectRevert(EngineToken.SupplyMismatch.selector);
        new EngineToken(tl, to, amt, address(r));
        // permit
        (address owner, uint256 pk) = makeAddrAndKey("owner");
        t.transfer(owner, 1 ether);
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                t.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        owner,
                        address(this),
                        1 ether,
                        0,
                        block.timestamp
                    )
                )
            )
        );
        (uint8 vv, bytes32 rr, bytes32 ss) = vm.sign(pk, digest);
        t.permit(owner, address(this), 1 ether, block.timestamp, vv, rr, ss);
        assertEq(t.allowance(owner, address(this)), 1 ether);
    }
}
