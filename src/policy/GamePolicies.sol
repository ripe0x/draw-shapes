// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Governed} from "../Governed.sol";
import {IBoardPolicy, IPricingPolicy, IGrailPolicy} from "../interfaces/IDrawShapes.sol";

/// @title BoardPolicy
/// @notice The board: a list of rows, each a prize kind (0 Shape, 1 Pack) and its backing. FwaGame keeps one
///         listing per row and replaces a row when its prize is won. `listBatch` bounds listings per sync.
/// @dev A module; FwaGame enforces its own bounds (`MAX_BOARD`, `MAX_LIST_BATCH`).
contract BoardPolicy is IBoardPolicy, Governed {
    struct Row {
        uint8 kind;
        uint96 backing;
    }

    Row[] internal _rows;
    uint256 public listBatch;

    event BoardSet(uint256 rows, uint256 listBatch);

    constructor(address governance_, uint8[] memory kinds, uint96[] memory backings, uint256 listBatch_)
        Governed(governance_, false)
    {
        _setBoard(kinds, backings, listBatch_);
    }

    function rowCount() external view returns (uint256) {
        return _rows.length;
    }

    function rowAt(uint256 index) external view returns (uint8 kind, uint96 backing) {
        Row memory r = _rows[index];
        return (r.kind, r.backing);
    }

    function setBoard(uint8[] calldata kinds, uint96[] calldata backings, uint256 listBatch_)
        external
        onlyGovernance
    {
        _setBoard(kinds, backings, listBatch_);
    }

    function _setBoard(uint8[] memory kinds, uint96[] memory backings, uint256 listBatch_) internal {
        if (kinds.length != backings.length || kinds.length > 200 || listBatch_ == 0 || listBatch_ > 20) {
            revert OutOfBounds();
        }
        delete _rows;
        for (uint256 i; i < kinds.length; ++i) {
            if (kinds[i] > 1 || backings[i] == 0) revert OutOfBounds();
            _rows.push(Row(kinds[i], backings[i]));
        }
        listBatch = listBatch_;
        emit BoardSet(kinds.length, listBatch_);
    }
}

/// @title PricingPolicy
/// @notice Listing price = prize cost (backing + mint fees) × (1 + markup). The markup is earmarked for keeper
///         gas. Also sets the prize-conversion bonus rate.
contract PricingPolicy is IPricingPolicy, Governed {
    uint256 internal constant BPS = 10_000;

    uint256 public markupBps;
    uint256 public conversionBonusBps;

    event PricingSet(uint256 markupBps, uint256 conversionBonusBps);

    constructor(address governance_, uint256 markupBps_, uint256 conversionBonusBps_) Governed(governance_, false) {
        _set(markupBps_, conversionBonusBps_);
    }

    function listPrice(uint8, uint256, uint256 cost) external view returns (uint256) {
        return cost * (BPS + markupBps) / BPS;
    }

    function set(uint256 markupBps_, uint256 conversionBonusBps_) external onlyGovernance {
        _set(markupBps_, conversionBonusBps_);
    }

    function _set(uint256 markupBps_, uint256 conversionBonusBps_) internal {
        if (markupBps_ > 500 || conversionBonusBps_ > 500) revert OutOfBounds();
        markupBps = markupBps_;
        conversionBonusBps = conversionBonusBps_;
        emit PricingSet(markupBps_, conversionBonusBps_);
    }
}

/// @title GrailPolicy
/// @notice GRAILs: large Shapes listed below backing. GRAIL number `step` has backing `ladder[step]` (the last
///         rung repeats). It lists at `startBps` of backing and loses `decayBps` every `decayPulls` booked
///         pulls, down to `floorBps`. FwaGame clamps the result to its hard bounds (price at least 50% of
///         backing, win probability at most 10%).
contract GrailPolicy is IGrailPolicy, Governed {
    uint256 internal constant BPS = 10_000;

    uint256[] internal _ladder;
    uint256 public startBps;
    uint256 public floorBps;
    uint256 public decayBps;
    uint256 public decayPulls;

    event GrailPolicySet(uint256[] ladder, uint256 startBps, uint256 floorBps, uint256 decayBps, uint256 decayPulls);

    constructor(
        address governance_,
        uint256[] memory ladder_,
        uint256 startBps_,
        uint256 floorBps_,
        uint256 decayBps_,
        uint256 decayPulls_
    ) Governed(governance_, false) {
        _set(ladder_, startBps_, floorBps_, decayBps_, decayPulls_);
    }

    function ladder() external view returns (uint256[] memory) {
        return _ladder;
    }

    function grailBacking(uint256 step) external view returns (uint256) {
        uint256 n = _ladder.length;
        if (n == 0) return 0;
        return _ladder[step < n ? step : n - 1];
    }

    function grailPrice(uint256 backing, uint256 pullsSinceListed) external view returns (uint256) {
        uint256 cut = decayBps * (pullsSinceListed / decayPulls);
        uint256 bps = startBps > floorBps + cut ? startBps - cut : floorBps;
        return backing * bps / BPS;
    }

    function set(
        uint256[] calldata ladder_,
        uint256 startBps_,
        uint256 floorBps_,
        uint256 decayBps_,
        uint256 decayPulls_
    ) external onlyGovernance {
        _set(ladder_, startBps_, floorBps_, decayBps_, decayPulls_);
    }

    function _set(
        uint256[] memory ladder_,
        uint256 startBps_,
        uint256 floorBps_,
        uint256 decayBps_,
        uint256 decayPulls_
    ) internal {
        if (ladder_.length > 8 || startBps_ > BPS || floorBps_ > startBps_ || decayPulls_ == 0) revert OutOfBounds();
        _ladder = ladder_;
        startBps = startBps_;
        floorBps = floorBps_;
        decayBps = decayBps_;
        decayPulls = decayPulls_;
        emit GrailPolicySet(ladder_, startBps_, floorBps_, decayBps_, decayPulls_);
    }
}
