// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IForeignController} from "../interfaces/IForeignController.sol";
import {IPool, IPoolTypes} from "../interfaces/IPool.sol";
import {FeeSplit} from "./FeeSplit.sol";

/// @notice Controller of one foreign listing lent by a sponsor.
/// @dev The pool lists the token at `parkedPriceWei` and holds it until it is captured, reclaimed or
///      rescued. The phase is Parked while the sponsor is owed mint fees (`feeSplit.paidWei() <
///      feeSplit.capWei()`) and Hot after. A Hot listing decays toward `floorWei` by
///      `decayWeiPerPull` per settled pull, applied by `tick`. The owner is `feeSplit.owner()`.
contract SponsoredPrize is IForeignController {
    enum Phase {
        Parked,
        Hot
    }

    error NotOwner();
    error NotSponsor();
    error NotPool();
    error ZeroAddress();
    error BadTerms();
    error AlreadyStarted();
    error NotStarted();
    error UnknownEntry();
    error WrongPhase();
    error TooEarly(uint256 reclaimAfter);
    error NotUnlisted();
    error WrongDestination();

    event Started(uint256 indexed listingId, uint256 pull);
    event Repriced(uint256 priceWei);
    event Captured(uint256 proceeds);

    IPool public immutable pool;
    FeeSplit public immutable feeSplit;
    address public immutable sponsor;
    address public immutable collection;
    uint256 public immutable tokenId;
    uint256 public immutable parkedPriceWei;
    uint256 public immutable floorWei;
    uint256 public immutable decayWeiPerPull;
    uint256 public immutable reclaimAfter;

    uint256 public listingId;
    uint256 public startedAt;
    uint64 public listedAtPull;
    uint64 public hotFromPull;
    bool public hotStarted;
    bool public captured;

    constructor(
        address pool_,
        address feeSplit_,
        address sponsor_,
        address collection_,
        uint256 tokenId_,
        uint256 parkedPriceWei_,
        uint256 floorWei_,
        uint256 decayWeiPerPull_,
        uint256 reclaimAfter_
    ) {
        if (pool_ == address(0) || feeSplit_ == address(0) || sponsor_ == address(0) || collection_ == address(0)) {
            revert ZeroAddress();
        }
        if (floorWei_ == 0 || floorWei_ > parkedPriceWei_ || decayWeiPerPull_ == 0) revert BadTerms();
        pool = IPool(pool_);
        feeSplit = FeeSplit(payable(feeSplit_));
        sponsor = sponsor_;
        collection = collection_;
        tokenId = tokenId_;
        parkedPriceWei = parkedPriceWei_;
        floorWei = floorWei_;
        decayWeiPerPull = decayWeiPerPull_;
        reclaimAfter = reclaimAfter_;
    }

    /// @notice Records the pool listing of this deal. Owner only, once, after `Pool.registerForeign`
    ///         named this contract as the controller.
    function start(uint256 listingId_) external {
        _requireOwner();
        if (listingId != 0) revert AlreadyStarted();
        IPoolTypes.ForeignListing[] memory all = pool.foreignListings();
        bool found;
        for (uint256 i; i < all.length; ++i) {
            if (
                all[i].listingId == listingId_ && all[i].controller == address(this) && all[i].collection == collection
                    && all[i].tokenId == tokenId
            ) found = true;
        }
        if (!found) revert UnknownEntry();
        listingId = listingId_;
        listedAtPull = pool.grail().pulls;
        startedAt = block.timestamp;
        emit Started(listingId_, listedAtPull);
    }

    /// @notice True while the pool lists the token for this deal: started, not captured, and the pool
    ///         entry exists with a nonzero price.
    function active() public view returns (bool) {
        if (listingId == 0 || captured) return false;
        (bool found, uint256 notional) = _entry();
        return found && notional != 0;
    }

    /// @notice Parked while the sponsor has not been paid the cap, Hot after.
    function phase() public view returns (Phase) {
        return feeSplit.paidWei() < feeSplit.capWei() ? Phase.Parked : Phase.Hot;
    }

    /// @notice Lowers the listing price to `max(floorWei, parkedPriceWei - decayWeiPerPull * pullsSinceHot)`
    ///         when that is at least 1 percent below the current price, or the floor itself. Does nothing
    ///         in Parked. A pool revert with `FwaBusy`, `ProbCapExceeded` or `ListingNotActive` leaves the
    ///         price unchanged and is retried by the next call.
    function tick() external {
        if (!active() || phase() != Phase.Hot) return;
        uint64 pulls = pool.grail().pulls;
        if (!hotStarted) {
            hotStarted = true;
            hotFromPull = pulls;
        }
        uint256 drop = decayWeiPerPull * (pulls - hotFromPull);
        uint256 next = drop >= parkedPriceWei - floorWei ? floorWei : parkedPriceWei - drop;
        (, uint256 current) = _entry();
        if (next >= current) return;
        if (next != floorWei && next * 100 > current * 99) return;
        try pool.repriceForeign(listingId, next) {
            emit Repriced(next);
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            if (
                sel != IPoolTypes.FwaBusy.selector && sel != IPoolTypes.ProbCapExceeded.selector
                    && sel != IPoolTypes.ListingNotActive.selector
            ) {
                assembly ("memory-safe") {
                    revert(add(err, 0x20), mload(err))
                }
            }
        }
    }

    /// @notice Returns the token to the sponsor. Sponsor only, in Parked, from `reclaimAfter`, while the
    ///         token is unwon.
    function reclaim() external {
        if (msg.sender != sponsor) revert NotSponsor();
        if (listingId == 0) revert NotStarted();
        if (captured || phase() != Phase.Parked) revert WrongPhase();
        if (block.timestamp < reclaimAfter) revert TooEarly(reclaimAfter);
        pool.withdrawForeign(listingId, sponsor);
    }

    /// @notice Pool callback with the capture proceeds. Marks the deal captured and adds the value to
    ///         the pool's GRAIL fund.
    function onForeignCapture(uint256, uint256, uint256) external payable {
        if (msg.sender != address(pool)) revert NotPool();
        captured = true;
        emit Captured(msg.value);
        if (msg.value != 0) pool.fundGrail{value: msg.value}();
    }

    /// @notice Withdraws the token to `to` after a refunded delivery left the pool entry unlisted.
    ///         Owner only. In Parked the token belongs to the sponsor, so `to` must be the sponsor.
    function rescue(address to) external {
        _requireOwner();
        if (listingId == 0) revert NotStarted();
        (bool found, uint256 notional) = _entry();
        if (!found || notional != 0) revert NotUnlisted();
        if (phase() == Phase.Parked && to != sponsor) revert WrongDestination();
        pool.withdrawForeign(listingId, to);
    }

    function _requireOwner() private view {
        if (msg.sender != feeSplit.owner()) revert NotOwner();
    }

    /// @dev The pool entry of `listingId`: whether it exists and its current price (zero while unlisted).
    function _entry() private view returns (bool found, uint256 notional) {
        IPoolTypes.ForeignListing[] memory all = pool.foreignListings();
        for (uint256 i; i < all.length; ++i) {
            if (all[i].listingId == listingId) return (true, all[i].notional);
        }
    }
}
