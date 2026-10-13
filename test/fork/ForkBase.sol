// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IShapes} from "shapes/interfaces/IShapes.sol";
import {IFWACloneFactory} from "../../src/interfaces/IFWACloneFactory.sol";

/// @notice Mainnet fork base. Forks Ethereum mainnet at `FORK_BLOCK` and exposes the deployed
///         Shapes collection and FWA factory, plus the factory-owner prank that opens pool
///         creation and purchases.
/// @dev `setUpFork()` reads `MAINNET_RPC_URL` (default: Tenderly public gateway) and `FORK_BLOCK`
///      from the environment. Addresses match `deployments/dependencies.json`, chain 1.
abstract contract ForkBase is Test {
    uint256 internal constant FORK_BLOCK = 26_040_413;

    address internal constant SHAPES_ADDR = 0x6fE9193276bF7aBCbEE44AB7aFd717d637D6FAf0;
    address internal constant SHAPE_PACKS_ADDR = 0xf21514B090Da7dF4390803497d6ae673801E5cA7;
    address internal constant FACTORY_ADDR = 0xa1e8e92609708AbA08E0A66e811C41cdBBF610Fa;

    IShapes internal shapes = IShapes(SHAPES_ADDR);
    IFWACloneFactory internal factory = IFWACloneFactory(FACTORY_ADDR);

    function setUpFork() internal {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string("https://gateway.tenderly.co/public/mainnet"));
        vm.createSelectFork(rpc, vm.envOr("FORK_BLOCK", FORK_BLOCK));
        vm.chainId(31337);
    }

    /// @dev Pranks the factory owner to enable pool creation (no beta gate, zero fee), purchases
    ///      and VRF requests.
    function openFactory() internal {
        address factoryOwner = factory.owner();
        vm.startPrank(factoryOwner);
        factory.setBetaAccess(false);
        factory.setMaxPoolsPerWallet(10);
        factory.setPoolCreationConfig(true, 0);
        factory.setGlobalPurchasesEnabled(true);
        factory.setVrfRequestsPaused(false);
        vm.stopPrank();

        assertFalse(factory.betaAccess(), "betaAccess not disabled");
        assertEq(factory.maxPoolsPerWallet(), 10, "maxPoolsPerWallet mismatch");
        assertTrue(factory.poolCreationEnabled(), "poolCreationEnabled false");
        assertEq(factory.poolCreationFee(), 0, "poolCreationFee not 0");
        assertTrue(factory.globalPurchasesEnabled(), "globalPurchasesEnabled false");
        assertFalse(factory.vrfRequestsPaused(), "vrfRequestsPaused still true");
    }

    /// @dev Mints `qty` Shapes of `amountWei` backing to `to`, which must be an EOA or implement
    ///      `onERC721Received`.
    function mintShapes(address to, uint256 amountWei, uint256 qty) internal returns (uint256 firstId) {
        uint256 cost = qty * (amountWei + shapes.mintFee());
        vm.deal(to, to.balance + cost);
        vm.prank(to);
        firstId = shapes.mintBatchTo{value: cost}(amountWei, qty, to);
    }
}
