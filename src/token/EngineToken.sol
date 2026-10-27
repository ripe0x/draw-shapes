// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "solady/tokens/ERC20.sol";
import {Governed} from "../Governed.sol";
import {IMetadataRenderer} from "../interfaces/IDrawShapes.sol";

/// @title EngineToken (ENGINE)
/// @notice The Draw Shapes token. The whole supply, 1,000,000,000 ENGINE, is minted once in the constructor to
///         the recipients the deploy script passes (ProtocolLiquidity and GenesisFarm). There is no mint
///         function, no transfer restriction and no upgrade path. Holders may burn their own tokens.
///         ERC-2612 permit is inherited from Solady. Metadata (`contractURI`, `tokenURI`) comes from a
///         replaceable renderer that only the timelock can set.
/// @dev ENGINE is not a claim on any ETH held by the game, its prizes, its vault or its buyback.
contract EngineToken is ERC20, Governed {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    IMetadataRenderer public renderer;

    event RendererSet(address renderer);

    error SupplyMismatch();
    error InvalidRenderer();

    constructor(address governance_, address[] memory recipients, uint256[] memory amounts, address renderer_)
        Governed(governance_, false)
    {
        if (recipients.length != amounts.length) revert SupplyMismatch();
        uint256 sum;
        for (uint256 i; i < recipients.length; ++i) {
            if (recipients[i] == address(0)) revert ZeroAddress();
            _mint(recipients[i], amounts[i]);
            sum += amounts[i];
        }
        if (sum != TOTAL_SUPPLY) revert SupplyMismatch();
        _setRenderer(renderer_);
    }

    function name() public pure override returns (string memory) {
        return "ENGINE";
    }

    function symbol() public pure override returns (string memory) {
        return "ENGINE";
    }

    /// @dev Constant name hash for the permit domain separator.
    function _constantNameHash() internal pure override returns (bytes32) {
        return keccak256("ENGINE");
    }

    /// @notice Burns `amount` of the caller's tokens.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @notice ERC-7572 contract metadata from the renderer.
    function contractURI() public view returns (string memory) {
        return renderer.contractURI(address(this));
    }

    /// @notice Same document as `contractURI`, for indexers that read `tokenURI()` on fungible tokens.
    function tokenURI() external view returns (string memory) {
        return contractURI();
    }

    function setRenderer(address renderer_) external onlyGovernance {
        _setRenderer(renderer_);
    }

    function _setRenderer(address renderer_) internal {
        if (renderer_.code.length == 0) revert InvalidRenderer();
        renderer = IMetadataRenderer(renderer_);
        emit RendererSet(renderer_);
    }
}
