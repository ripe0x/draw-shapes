// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {FwaGame} from "../../src/game/FwaGame.sol";
import {stdJson} from "forge-std/StdJson.sol";

/// @notice Gas receipts (BUILD_PROMPT rule 9), measured on the fork with every top-level call its own
///         transaction so storage is cold the way it is on chain:
///         `forge test --match-path test/fork/Gas.t.sol --isolate`. Writes docs/receipts/gas.json. Each figure is
///         the call's execution gas plus the 21,000 base cost (calldata is a few hundred gas more).
contract GasReceipts is ForkBase {
    using stdJson for string;

    address alice = makeAddr("alice");
    address keeper = makeAddr("keeper");
    string json = "gas";

    function setUp() public {
        deployLaunch();
        fundAndFill(OPENING_CAPITAL);
        openMarket();
        openGame();
    }

    function _pulls(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            uint256 id = pull(alice);
            vm.roll(block.number + 3);
            deliverWord(id, uint256(keccak256(abi.encode(i, n))));
            pool.processAcquisitions(10);
        }
    }

    function _record(string memory key, uint256 gas) internal {
        json.serialize(key, gas);
        emit log_named_uint(key, gas);
    }

    function test_gasReceipts() public {
        uint256 g;
        // the purchase gate keeps 80 prizes plus a full batch in the draw; measuring a 20-pull booking needs room for
        // 20 captures before a replacement lists, so the floor is lowered to 50%
        FwaGame.Capital memory c = cfg.capital;
        c.minLiveBps = 5_000;
        vm.prank(address(sys.timelock));
        sys.game.setCapital(c);
        // a player's pull (FWA's acquire, for reference)
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(1);
        uint256 version = pool.inventoryVersion();
        vm.deal(alice, 10 ether);
        g = gasleft();
        vm.prank(alice);
        pool.acquire{value: total}(alice, fee, 0, 10_000, version, block.timestamp + 1 hours);
        _record("acquire", g - gasleft() + 21_000);
        vm.roll(block.number + 3);
        deliverWord(pool.requestIdAtSequence(1), 1);
        pool.processAcquisitions(10);

        // sync: book 1 pull and list its replacement (at a maintenance window)
        vm.warp(block.timestamp + 30 minutes);
        g = gasleft();
        vm.prank(keeper);
        sys.game.sync(50);
        _record("sync_1", g - gasleft() + 21_000);

        // sync: 5 and 20 pulls in one call
        _pulls(5);
        vm.warp(block.timestamp + 30 minutes);
        g = gasleft();
        vm.prank(keeper);
        sys.game.sync(50);
        _record("sync_5", g - gasleft() + 21_000);
        _pulls(20);
        vm.warp(block.timestamp + 30 minutes);
        g = gasleft();
        vm.prank(keeper);
        sys.game.sync(50);
        _record("sync_20", g - gasleft() + 21_000);

        // a profit-funded buyback slice (bought and burned)
        vm.deal(address(sys.game), address(sys.game).balance + 1 ether);
        vm.prank(address(sys.game));
        (bool sent,) = address(sys.buyback).call{value: 1 ether}("");
        require(sent);
        g = gasleft();
        vm.prank(keeper);
        sys.buyback.process(0);
        _record("process_buyback", g - gasleft() + 21_000);

        // convert a delivered Shape
        uint256 lid;
        uint256 tokenId;
        for (uint256 l = 1; l < 200; ++l) {
            (bool ok,, uint256 t) = sys.converter.convertible(l);
            if (ok && shapes.ownerOf(t) == alice) {
                (lid, tokenId) = (l, t);
                break;
            }
        }
        vm.prank(alice);
        shapes.approve(address(sys.converter), tokenId);
        g = gasleft();
        vm.prank(alice);
        sys.converter.convert(lid, 0, true);
        _record("convert", g - gasleft() + 21_000);

        // claim one final epoch
        vm.roll(sys.farm.openBlock() + 7_200);
        vm.prank(keeper);
        try sys.game.sync(50) {} catch {}
        uint256[] memory es = new uint256[](1);
        g = gasleft();
        vm.prank(keeper);
        sys.farm.finalize(es);
        _record("finalize_1_epoch", g - gasleft() + 21_000);
        g = gasleft();
        vm.prank(alice);
        sys.farm.claim(es);
        _record("claim_1_epoch", g - gasleft() + 21_000);

        string memory out = json.serialize("fork_block", vm.envOr("FORK_BLOCK", FORK_BLOCK));
        vm.writeJson(out, "docs/receipts/gas.json");
    }
}
