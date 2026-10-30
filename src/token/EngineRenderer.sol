// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {IMetadataRenderer} from "../interfaces/IDrawShapes.sol";

interface IERC20Supply {
    function totalSupply() external view returns (uint256);
}

/// @title EngineRenderer
/// @notice On-chain metadata for ENGINE: a twelve-tooth gear drawn in SVG, with the share of supply burned
///         so far shown under the wordmark. A module; the timelock may replace it on the token.
contract EngineRenderer is IMetadataRenderer {
    using LibString for uint256;

    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000 ether;

    /// @inheritdoc IMetadataRenderer
    function contractURI(address token) external view returns (string memory) {
        uint256 supply = IERC20Supply(token).totalSupply();
        uint256 burned = TOTAL_SUPPLY > supply ? TOTAL_SUPPLY - supply : 0;
        string memory burnedPct = _pct(burned);
        string memory json = string.concat(
            '{"name":"ENGINE","symbol":"ENGINE","description":"The Draw Shapes token. Earned by playing during genesis; ',
            'a share of game revenue buys it back every day, half burned and half paid to that day\'s players.",',
            '"image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg(burnedPct))),
            '","burned_percent":"',
            burnedPct,
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// @notice The gear image with `burnedPct` in its caption.
    function svg(string memory burnedPct) public pure returns (string memory s) {
        s = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400"><rect width="400" height="400" fill="#0d0d0d"/>'
            '<g transform="translate(200 170)" fill="#f2f2f2">';
        for (uint256 i; i < 12; ++i) {
            s = string.concat(
                s, '<rect x="-14" y="-118" width="28" height="34" rx="4" transform="rotate(', (i * 30).toString(), ')"/>'
            );
        }
        s = string.concat(
            s,
            '<circle r="92"/><circle r="52" fill="#0d0d0d"/><circle r="22"/></g>',
            '<text x="200" y="340" text-anchor="middle" font-family="monospace" font-size="34" letter-spacing="6" fill="#f2f2f2">ENGINE</text>',
            '<text x="200" y="372" text-anchor="middle" font-family="monospace" font-size="14" fill="#8a8a8a">',
            burnedPct,
            "% burned</text></svg>"
        );
    }

    /// @dev `part / TOTAL_SUPPLY` as a percentage with two decimals.
    function _pct(uint256 part) internal pure returns (string memory) {
        uint256 bp = part * 10_000 / TOTAL_SUPPLY;
        uint256 frac = bp % 100;
        return string.concat((bp / 100).toString(), ".", frac < 10 ? "0" : "", frac.toString());
    }
}
