// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IShapes} from "shapes/interfaces/IShapes.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";
import {DeploySystem} from "../../script/DeploySystem.sol";
import {Swapper} from "../utils/Swapper.sol";
import {KeeperFund} from "../../src/treasury/KeeperFund.sol";

interface IVrfConsumerH {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
}

interface IVrfRoutedH {
    function s_vrfCoordinator() external view returns (address);
}

/// @notice Drives every public function of the system as one of four actors with fuzzed inputs, and checks
///         after each action that value moved only where it may (the custody rule, BUILD_PROMPT rule 7):
///         - an actor's ETH rises only by its own tip, its own FWA refund, its own Shape's backing, or what
///           the market pays it for ENGINE it sold;
///         - an actor's ENGINE rises only by its claim, its conversion (bought + bonus) or a market buy;
///         - no holder's ETH falls during an action that may not move it;
///         - privileged functions revert for every actor.
///         Each breach increments `violations` with a reason.
contract Handler is Test {
    address constant VRF_SERVICE = 0xA4adFC35dB18326eFB3b5D9bf66A8103Ec2D5EE2;

    DeploySystem.System internal s;
    IFWAPool public pool;
    IShapes public shapes;
    Swapper public swapper;
    address[4] public actors;

    uint256 public violations;
    string public lastViolation;
    uint256 public vaultFunded;
    mapping(bytes32 => uint256) public calls;

    uint256[] internal _pending; // request ids not yet given a word

    constructor(DeploySystem.System memory s_, IFWAPool pool_, address shapes_, address pm) {
        s = s_;
        pool = pool_;
        shapes = IShapes(shapes_);
        swapper = new Swapper(IPoolManager(pm), s_.liquidity.poolKey());
        for (uint256 i; i < 4; ++i) {
            actors[i] = makeAddr(string.concat("actor", vm.toString(i)));
            vm.deal(actors[i], 50 ether);
        }
        vaultFunded = s_.game.capitalIn();
    }

    // ------------------------------------------------------------------ bookkeeping

    struct Snap {
        uint256[4] eth;
        uint256[4] engine;
        uint256 vault;
        uint256 game;
        uint256 keeper;
        uint256 liquidity;
        uint256 tipsPaid;
    }

    function _snap() internal view returns (Snap memory x) {
        for (uint256 i; i < 4; ++i) {
            x.eth[i] = actors[i].balance + s.keeperFund.tipCredit(actors[i]);
            x.engine[i] = s.engine.balanceOf(actors[i]);
        }
        x.vault = address(s.vault).balance;
        x.game = address(s.game).balance + s.game.inventoryBacking();
        x.keeper = address(s.keeperFund).balance;
        x.liquidity = address(s.liquidity).balance;
        x.tipsPaid = s.keeperFund.totalTipsPaid();
    }

    function _flag(string memory why) internal {
        ++violations;
        lastViolation = why;
    }

    /// @dev After an action by `who`: every other actor's ETH and ENGINE unchanged; `who` within `ethAllowance`
    ///      and `engineAllowance`.
    function _checkActors(Snap memory b, uint256 who, uint256 ethAllowance, uint256 engineAllowance) internal {
        Snap memory a = _snap();
        for (uint256 i; i < 4; ++i) {
            uint256 ethCap = i == who ? ethAllowance : 0;
            uint256 engCap = i == who ? engineAllowance : 0;
            if (a.eth[i] > b.eth[i] + ethCap) _flag("actor ETH rose without cause");
            if (a.engine[i] > b.engine[i] + engCap) _flag("actor ENGINE rose without cause");
        }
    }

    function _checkHoldersKept(Snap memory b) internal {
        Snap memory a = _snap();
        if (a.vault < b.vault) _flag("vault ETH fell");
        if (a.game < b.game) _flag("game value fell");
        if (a.liquidity < b.liquidity) _flag("liquidity ETH fell");
    }

    function _actor(uint256 seed) internal view returns (uint256 i, address a) {
        i = seed % 4;
        a = actors[i];
    }

    // ------------------------------------------------------------------ player actions

    function pullOne(uint256 seed) external {
        (uint256 i, address a) = _actor(seed);
        if (pool.totalWeight() == 0 || !pool.localPurchasesEnabled()) return;
        if (block.timestamp < pool.purchasesResumeAt()) return;
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(1);
        uint256 version = pool.inventoryVersion();
        if (a.balance < total) return;
        Snap memory b = _snap();
        vm.prank(a);
        try pool.acquire{value: total}(a, fee, 0, 10_000, version, block.timestamp + 1 hours) returns (uint256 id) {
            _pending.push(id);
            ++calls["pull"];
        } catch {}
        _checkActors(b, i, 0, 0);
        _checkHoldersKept(b);
    }

    /// @dev Gives the oldest pending request a word on time, late (TimedOut) or never (left to expire).
    function settle(uint256 word, uint8 mode) external {
        if (_pending.length == 0) return;
        uint256 id = _pending[0];
        for (uint256 k; k + 1 < _pending.length; ++k) {
            _pending[k] = _pending[k + 1];
        }
        _pending.pop();
        Snap memory b = _snap();
        mode = mode % 4;
        if (mode == 3) {
            vm.roll(block.number + 31);
        } else {
            (, uint256 requestBlock,,,) = pool.acquisitions(id);
            if (mode == 2) vm.roll(requestBlock + 31);
            else if (block.number < requestBlock + 3) vm.roll(requestBlock + 3);
            uint256[] memory words = new uint256[](1);
            words[0] = word;
            vm.prank(IVrfRoutedH(VRF_SERVICE).s_vrfCoordinator());
            IVrfConsumerH(VRF_SERVICE).rawFulfillRandomWords(id, words);
        }
        ++calls["settle"];
        _checkActors(b, 9, 0, 0);
        _checkHoldersKept(b);
    }

    function keeperSync(uint256 seed, uint256 maxCount) external {
        (uint256 i, address a) = _actor(seed);
        Snap memory b = _snap();
        uint256 distributed = s.game.distributed();
        vm.prank(a);
        try s.game.sync(bound(maxCount, 1, 50)) {
            ++calls["sync"];
        } catch {}
        Snap memory x = _snap();
        _checkActors(b, i, x.tipsPaid - b.tipsPaid, 0);
        // profit rule: a distribution needs realised profit and leaves protected cash intact
        if (s.game.distributed() > distributed) {
            if (s.game.cash() < s.game.protectedCash()) _flag("profit left below protected cash");
            int256 p = s.game.profit();
            if (p < 0 || s.game.distributed() > uint256(p)) _flag("distributed more than realised profit");
        }
    }

    function convert(uint256 seed) external {
        (uint256 i, address a) = _actor(seed);
        uint256 listingId;
        uint256 tokenId;
        for (uint256 lid = 1; lid < 400; ++lid) {
            (bool ok, address collection, uint256 t) = s.converter.convertible(lid);
            if (ok && collection == address(shapes) && _ownerOf(t) == a) {
                (listingId, tokenId) = (lid, t);
                break;
            }
        }
        if (listingId == 0) return;
        uint256 value = shapes.valueOf(tokenId);
        Snap memory b = _snap();
        vm.startPrank(a);
        shapes.approve(address(s.converter), tokenId);
        uint256 out;
        uint256 bonus;
        try s.converter.convert(listingId, 0, true) returns (uint256 o, uint256 bo) {
            (out, bonus) = (o, bo);
            ++calls["convert"];
        } catch {}
        vm.stopPrank();
        _checkActors(b, i, value, out + bonus);
        _checkHoldersKept(b);
    }

    function _ownerOf(uint256 t) internal view returns (address o) {
        try shapes.ownerOf(t) returns (address x) {
            o = x;
        } catch {}
    }

    function burnOwnShape(uint256 seed) external {
        (uint256 i, address a) = _actor(seed);
        for (uint256 lid = 1; lid < 400; ++lid) {
            (uint48 t,,,,,,,) = s.game.items(lid);
            if (t != 0 && _ownerOf(t) == a) {
                uint256 value = shapes.valueOf(t);
                Snap memory b = _snap();
                vm.prank(a);
                shapes.burn(t);
                ++calls["burnShape"];
                _checkActors(b, i, value, 0);
                _checkHoldersKept(b);
                return;
            }
        }
    }

    function withdrawRefund(uint256 seed) external {
        (uint256 i, address a) = _actor(seed);
        uint256 credit = pool.acquisitionRefundCredit(a);
        if (credit == 0) return;
        Snap memory b = _snap();
        vm.prank(a);
        pool.withdrawAcquisitionRefund();
        ++calls["refund"];
        _checkActors(b, i, credit, 0);
        _checkHoldersKept(b);
    }

    function claim(uint256 seed) external {
        (uint256 i, address a) = _actor(seed);
        uint256 cur = s.farm.currentEpoch();
        uint256[] memory es = new uint256[](1);
        for (uint256 e; e <= cur && e < 60; ++e) {
            if (s.farm.claimed(e, a) || !s.farm.isFinal(e) || s.farm.rewardOf(e, a) == 0) continue;
            es[0] = e;
            Snap memory b = _snap();
            vm.prank(a);
            uint256 got = s.farm.claim(es);
            ++calls["claim"];
            _checkActors(b, i, 0, got);
            _checkHoldersKept(b);
            return;
        }
    }

    // ------------------------------------------------------------------ keeper jobs

    function buyback(uint256 seed) external {
        (uint256 i, address a) = _actor(seed);
        Snap memory b = _snap();
        vm.prank(a);
        try s.buyback.process(0) {
            ++calls["buyback"];
        } catch {}
        Snap memory x = _snap();
        _checkActors(b, i, x.tipsPaid - b.tipsPaid, 0);
        if (x.vault < b.vault || x.game < b.game) _flag("buyback moved game ETH");
    }

    function fundVault(uint256 amount) external {
        amount = bound(amount, 0, 2 ether);
        vm.deal(address(s.vault), address(s.vault).balance + amount);
        vaultFunded += amount; // counted whether it reaches the game or stays in the vault
        try s.vault.fund() {
            ++calls["fund"];
        } catch {}
    }

    // ------------------------------------------------------------------ market

    function marketBuy(uint256 seed, uint256 eth) external {
        (uint256 i, address a) = _actor(seed);
        eth = bound(eth, 0.001 ether, 1 ether);
        if (a.balance < eth) return;
        Snap memory b = _snap();
        uint256 out;
        vm.prank(a);
        try swapper.buy{value: eth}(eth, false) returns (uint256, uint256 o) {
            out = o;
            ++calls["buy"];
        } catch {}
        _checkActors(b, i, 0, out);
        _checkHoldersKept(b);
    }

    function marketSell(uint256 seed, uint256 frac) external {
        (uint256 i, address a) = _actor(seed);
        uint256 bal = s.engine.balanceOf(a);
        if (bal == 0) return;
        uint256 amount = bal * bound(frac, 1, 100) / 100;
        Snap memory b = _snap();
        uint256 got;
        vm.startPrank(a);
        s.engine.approve(address(swapper), amount);
        try swapper.sell(amount, false) returns (uint256, uint256 o) {
            got = o;
            ++calls["sell"];
        } catch {
            _flag("sell reverted");
        }
        vm.stopPrank();
        _checkActors(b, i, got, 0);
        _checkHoldersKept(b);
    }

    // ------------------------------------------------------------------ time and attacks

    function warp(uint256 secs) external {
        secs = bound(secs, 12, 2 days);
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + secs / 12);
        ++calls["warp"];
    }

    function donate(uint256 which, uint256 amount) external {
        amount = bound(amount, 0, 0.5 ether);
        address[5] memory t =
            [address(s.vault), address(s.game), address(s.buyback), address(s.keeperFund), address(s.liquidity)];
        address target = t[which % 5];
        vm.deal(address(this), amount);
        (bool ok,) = target.call{value: amount}("");
        ok;
        if (target == address(s.vault)) vaultFunded += amount;
        ++calls["donate"];
    }

    /// @dev Privileged calls from an actor must revert.
    function attack(uint256 seed, uint256 fn) external {
        (, address a) = _actor(seed);
        bytes memory data;
        address target;
        fn = fn % 17;
        if (fn == 0) {
            (target, data) = (address(s.vault), abi.encodeCall(s.vault.setActiveGame, (a)));
        } else if (fn == 1) {
            (target, data) = (address(s.vault), abi.encodeCall(s.vault.retireGame, ()));
        } else if (fn == 2) {
            (target, data) = (address(s.vault), abi.encodeCall(s.vault.repay, (true)));
        } else if (fn == 3) {
            (target, data) = (address(s.game), abi.encodeCall(s.game.retire, ()));
        } else if (fn == 4) {
            (target, data) = (address(s.game), abi.encodeCall(s.game.setModule, ("buyer", address(this))));
        } else if (fn == 5) {
            (target, data) = (address(s.buyback), abi.encodeCall(s.buyback.setSource, (a, true)));
        } else if (fn == 6) {
            (target, data) = (address(s.keeperFund), abi.encodeCall(s.keeperFund.tip, (a, 1e6, 20, true)));
        } else if (fn == 7) {
            (target, data) = (address(s.farm), abi.encodeCall(s.farm.payBonus, (a, 1)));
        } else if (fn == 8) {
            (target, data) = (address(s.farm), abi.encodeCall(s.farm.addLedger, (a)));
        } else if (fn == 9) {
            (target, data) = (address(s.buyer), abi.encodeCall(s.buyer.buy, (0, a, 100)));
        } else if (fn == 10) {
            (target, data) = (address(s.liquidity), abi.encodeCall(s.liquidity.addLiquidity, (0)));
        } else if (fn == 11) {
            (target, data) = (address(s.engine), abi.encodeCall(s.engine.setRenderer, (a)));
        } else if (fn == 12) {
            (target, data) = (address(s.hook), abi.encodeCall(s.hook.setPolicy, (a)));
        } else if (fn == 13) {
            (target, data) =
            (address(s.game), abi.encodeCall(s.game.startPromotion, (0.01 ether, 5_000, block.number + 10)));
        } else if (fn == 14) {
            (target, data) = (address(s.game), abi.encodeCall(s.game.receiveFunding, ()));
        } else if (fn == 15) {
            (target, data) = (address(s.game), abi.encodeCall(s.game.returnOps, ()));
        } else {
            (target, data) = (address(s.farm), abi.encodeCall(s.farm.start, ()));
        }
        Snap memory b = _snap();
        vm.prank(a);
        (bool ok,) = target.call(data);
        if (ok) _flag("privileged call succeeded");
        _checkHoldersKept(b);
        ++calls["attack"];
    }

    function pendingCount() external view returns (uint256) {
        return _pending.length;
    }

    receive() external payable {}
}
