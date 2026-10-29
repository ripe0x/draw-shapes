// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Governed} from "../Governed.sol";
import {IBoardPolicy, IPricingPolicy} from "../interfaces/IDrawShapes.sol";

/// @title BoardPolicy
/// @notice The board: a list of rows, each a prize kind (0 Shape, 1 Shape Pack) and its backing. FwaGame keeps one
///         listing per row and replaces a row when its prize is won. `listBatch` is the number of empty rows that opens
///         a replacement window (D49). A Pack row must be at least Shape Packs' minimum (`minPackBacking`, 0.03 ETH
///         on mainnet); its prize is minted with the fewest Shapes adding up to its backing.
/// @dev A module; FwaGame enforces its own bounds (`MAX_BOARD`, `MAX_LIST_BATCH`).
contract BoardPolicy is IBoardPolicy, Governed {
    struct Row {
        uint8 kind;
        uint96 backing;
    }

    Row[] internal _rows;
    uint256 public listBatch;
    uint256 public immutable minPackBacking;

    event BoardSet(uint256 rows, uint256 listBatch);

    constructor(
        address governance_,
        uint256 minPackBacking_,
        uint8[] memory kinds,
        uint96[] memory backings,
        uint256 listBatch_
    ) Governed(governance_, false) {
        minPackBacking = minPackBacking_;
        _setBoard(kinds, backings, listBatch_);
    }

    function rowCount() external view returns (uint256) {
        return _rows.length;
    }

    function rowAt(uint256 index) external view returns (uint8 kind, uint96 backing) {
        Row memory r = _rows[index];
        return (r.kind, r.backing);
    }

    function setBoard(uint8[] calldata kinds, uint96[] calldata backings, uint256 listBatch_) external onlyGovernance {
        _setBoard(kinds, backings, listBatch_);
    }

    function _setBoard(uint8[] memory kinds, uint96[] memory backings, uint256 listBatch_) internal {
        if (kinds.length != backings.length || kinds.length > 200 || listBatch_ == 0 || listBatch_ > 20) {
            revert OutOfBounds();
        }
        delete _rows;
        for (uint256 i; i < kinds.length; ++i) {
            if (kinds[i] > 1 || backings[i] == 0 || (kinds[i] == 1 && backings[i] < minPackBacking)) {
                revert OutOfBounds();
            }
            _rows.push(Row(kinds[i], backings[i]));
        }
        listBatch = listBatch_;
        emit BoardSet(kinds.length, listBatch_);
    }
}

/// @title PricingPolicy
/// @notice Listing price = prize cost (backing + mint fee) × (1 + markup). Also sets the operating allocation (bps of a
///         quote's expected replacement cost, paid to KeeperFund) and the prize-conversion bonus rate.
contract PricingPolicy is IPricingPolicy, Governed {
    uint256 internal constant BPS = 10_000;

    uint256 public markupBps;
    uint256 public conversionBonusBps;
    uint256 public opsBps;

    event PricingSet(uint256 markupBps, uint256 conversionBonusBps, uint256 opsBps);

    constructor(address governance_, uint256 markupBps_, uint256 conversionBonusBps_, uint256 opsBps_)
        Governed(governance_, false)
    {
        _set(markupBps_, conversionBonusBps_, opsBps_);
    }

    function listPrice(uint8, uint256, uint256 cost) external view returns (uint256) {
        return cost * (BPS + markupBps) / BPS;
    }

    function set(uint256 markupBps_, uint256 conversionBonusBps_, uint256 opsBps_) external onlyGovernance {
        _set(markupBps_, conversionBonusBps_, opsBps_);
    }

    /// @dev The operating allocation may not exceed the markup: it is paid out of the markup's share of proceeds.
    function _set(uint256 markupBps_, uint256 conversionBonusBps_, uint256 opsBps_) internal {
        if (markupBps_ > 500 || conversionBonusBps_ > 500 || opsBps_ > markupBps_) revert OutOfBounds();
        markupBps = markupBps_;
        conversionBonusBps = conversionBonusBps_;
        opsBps = opsBps_;
        emit PricingSet(markupBps_, conversionBonusBps_, opsBps_);
    }
}
