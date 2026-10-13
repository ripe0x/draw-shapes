// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title FWAConfigKeys
/// @notice Keys for FWA's consolidated owner-config setters (`setUint`/`setBool`/`setAddr`). The former
///         per-knob setters were merged into three generic dispatchers to keep FWA's runtime
///         bytecode under the 24,576-byte EIP-170 limit; these named constants keep call sites readable
///         (`pool.setUint(FWAConfigKeys.SURCHARGE_BPS, 1200)`). Constants live in a library so they inline
///         at zero bytecode cost in both FWA and its callers. Values are globally unique across all three
///         dispatchers so the emitted `ConfigSet(key, value)` event is unambiguous for indexers.
library FWAConfigKeys {
    // --- constructor / FWAVRFService request-tuple events (not accepted by setUint) ---
    uint256 internal constant CALLBACK_GAS_LIMIT = 1;
    uint256 internal constant VRF_KEY_HASH = 24;

    // --- setUint (uint256 value) ---
    uint256 internal constant VRF_SUB_ID = 2;
    // Values 3..6 are intentionally unused. VRF service-fee pricing, callback coverage and subscription
    // funding moved into the external FWAVRFService before deployment.
    uint256 internal constant REQUEST_CONFIRMATIONS = 7;
    // Values 8 and 9 are intentionally unused. Block maturity and the separate callback window were
    // replaced before deployment by request-time reservation plus `SELECTION_TIMEOUT_BLOCKS`.
    uint256 internal constant MAX_ACTIVATIONS_PER_ACQUISITION = 10;
    uint256 internal constant SELECTION_TIMEOUT_BLOCKS = 11;
    uint256 internal constant MAX_ACQUISITIONS_PER_TX = 12;
    uint256 internal constant SURCHARGE_BPS = 13;
    uint256 internal constant SELECTION_SLIPPAGE_BPS = 14;
    uint256 internal constant TOP_LISTING_SHARE_BPS = 15;
    uint256 internal constant TOP_THRESHOLD_BPS = 16;
    uint256 internal constant SETTLEMENT_DISCOUNT_BPS = 17;
    uint256 internal constant OWNER_ACQUISITION_FEE_BPS = 18;
    uint256 internal constant OWNER_SETTLEMENT_FEE_BPS = 19;
    uint256 internal constant SETTLEMENT_WINDOW = 20;
    uint256 internal constant FINALIZE_WINDOW = 21;
    uint256 internal constant MIN_BACKING = 22;
    uint256 internal constant PROTOCOL_FEE_TO_TOKEN_BPS = 23;
    uint256 internal constant MAX_STAGED_LISTINGS = 25;

    // --- setBool (bool value) ---
    uint256 internal constant RETAINED_TO_PROTOCOL = 40;
    uint256 internal constant ACQUISITIONS_ENABLED = 41;
    uint256 internal constant WITHDRAW_ONLY = 42;
    uint256 internal constant WHITELIST_ENABLED = 43;
    uint256 internal constant ACCEPT_BID_AS_TOKENS_ENABLED = 44;
    uint256 internal constant ROUTE_ACQUISITION_PROCEEDS_TO_AUTO_RELOAD = 45;

    // --- setAddr (address value) ---
    uint256 internal constant VRF_COORDINATOR = 60;
    uint256 internal constant PAYOUT_ADDRESS = 61;
    uint256 internal constant WHITELIST_MANAGER = 62;
    /// @dev Constructor-only immutable address, emitted through ConfigSet but not accepted by setAddr.
    uint256 internal constant VRF_SERVICE = 63;
}
