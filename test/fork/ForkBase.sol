// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IShapes} from "shapes/interfaces/IShapes.sol";
import {IFWAPool, IFWAFactory} from "../../src/interfaces/IFWA.sol";
import {LaunchConfig} from "../../script/LaunchConfig.sol";

/// @dev The VRF consumer callback. The FWA VRF service is the registered Chainlink consumer and forwards each
///      word to the pool that paid for it.
interface IVrfConsumer {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
}

/// @dev `VRFConsumerBaseV2Plus.s_vrfCoordinator`, the only caller the FWA VRF service accepts a callback from.
interface IVrfRouted {
    function s_vrfCoordinator() external view returns (address);
}

/// @notice Mainnet fork base. Forks Ethereum mainnet at `FORK_BLOCK` (env `FORK_BLOCK`, default below) from
///         `MAINNET_RPC_URL` (default: the Tenderly public gateway) and deploys the whole system against the real
///         Shapes, Shape Packs, FWA factory and VRF service, and the real Uniswap v4 PoolManager, with the launch
///         configuration. Addresses match `deployments/dependencies.json`, chain 1.
abstract contract ForkBase is Test, LaunchConfig {
    uint256 internal constant FORK_BLOCK = 26_279_000;

    address internal constant SHAPES = 0x6fE9193276bF7aBCbEE44AB7aFd717d637D6FAf0;
    address internal constant SHAPE_PACKS = 0xf21514B090Da7dF4390803497d6ae673801E5cA7;
    address internal constant FACTORY = 0xF5A3A153164791AB579C3d9ba5DBECf7cDfd300c;
    address internal constant FWA_IMPL = 0xEaa4d032908A9734a2c7939c0D211c35ad51eb31;
    address internal constant VRF_SERVICE = 0xA4adFC35dB18326eFB3b5D9bf66A8103Ec2D5EE2;
    address internal constant FWA_TOKEN = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    address internal gov = makeAddr("governance");
    IShapes internal shapes = IShapes(SHAPES);
    IFWAFactory internal factory = IFWAFactory(FACTORY);

    System internal sys;
    IFWAPool internal pool;
    Config internal cfg;

    function setUpFork() internal {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string("https://gateway.tenderly.co/public/mainnet"));
        vm.createSelectFork(rpc, vm.envOr("FORK_BLOCK", FORK_BLOCK));
    }

    /// @dev Forks and deploys the launch system from this test contract, creating the FWA pool with the real
    ///      FWA fee purchase.
    function deployLaunch() internal {
        setUpFork();
        cfg = _launchConfig(gov, SHAPES, SHAPE_PACKS, FACTORY, FWA_IMPL, POOL_MANAGER);
        cfg.create2Deployer = address(this);
        cfg.fwaFeeEth = fwaFeeQuote(FACTORY, POOL_MANAGER, 500);
        vm.deal(address(this), cfg.fwaFeeEth + 1 ether);
        sys = _deploySystem(cfg, address(this));
        pool = sys.game.pool();
        postflight(cfg, sys, address(this));
    }

    // ------------------------------------------------------------------ launch sequence helpers

    /// @dev Governance funds the vault with `eth`, the vault funds the game, and `sync` fills the board.
    function fundAndFill(uint256 eth) internal {
        vm.deal(address(sys.vault), address(sys.vault).balance + eth);
        sys.vault.fund();
        for (uint256 i; i < 20 && sys.game.liveCount() < sys.board.rowCount(); ++i) {
            sys.game.sync(50);
        }
    }

    /// @dev Opens the ENGINE market with `eth` against the 10% float.
    function openMarket(uint256 eth) internal {
        vm.deal(address(sys.timelock), eth);
        vm.prank(address(sys.timelock));
        sys.liquidity.launch{value: eth}();
    }

    function openGame() internal {
        vm.prank(address(sys.timelock));
        sys.game.openGame();
    }

    // ------------------------------------------------------------------ pulls

    /// @dev One acquisition through the real FWA pool with `purchaser` paying the quoted total.
    function pull(address purchaser) internal returns (uint256 requestId) {
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(1);
        uint256 version = pool.inventoryVersion();
        vm.deal(purchaser, purchaser.balance + total);
        vm.prank(purchaser);
        requestId = pool.acquire{value: total}(purchaser, fee, 0, 10_000, version, block.timestamp + 1 hours);
    }

    /// @dev Delivers `word` the way a live fulfillment arrives: the coordinator calls the FWA VRF service, which
    ///      forwards it to the pool.
    function deliverWord(uint256 requestId, uint256 word) internal {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        vm.prank(IVrfRouted(VRF_SERVICE).s_vrfCoordinator());
        IVrfConsumer(VRF_SERVICE).rawFulfillRandomWords(requestId, words);
    }

    /// @dev Pull, wait the confirmations, deliver a word, and let FWA settle.
    function pullAndSettle(address purchaser, uint256 word) internal returns (uint256 requestId) {
        requestId = pull(purchaser);
        vm.roll(block.number + 3);
        deliverWord(requestId, word);
        pool.processAcquisitions(10);
    }

    function statusOf(uint256 requestId) internal view returns (IFWAPool.AcquisitionStatus st) {
        (,,,, st) = pool.acquisitions(requestId);
    }

    receive() external payable {}
}
