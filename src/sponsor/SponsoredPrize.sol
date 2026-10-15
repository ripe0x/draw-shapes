// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IForeignController} from "../interfaces/IForeignController.sol";
import {IPool, IPoolTypes} from "../interfaces/IPool.sol";
import {FeeSplit} from "./FeeSplit.sol";

/// @notice Controller of one foreign listing lent by a sponsor.
/// @dev The pool lists the token at `parkedPriceWei` and holds it until it is captured, reclaimed or
///      rescued. The phase is Parked while the sponsor is owed mint fees (`feeSplit.paidWei() <
///      capWei`) and Hot after. `capWei` and `sponsor` are fixed at construction, and `start` requires
///      `feeSplit` to hold the same values and locks it until the deal ends. A Hot listing decays
///      toward `floorWei` by `decayWeiPerPull` per settled pull, applied by `tick`. The owner is
///      `feeSplit.owner()`. A token the pool exports to this contract is sent on by `releaseHeld`.
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
    error TermsMismatch();
    error WrongToken();
    error NotParty();

    event Started(uint256 indexed listingId, uint256 pull);
    event Repriced(uint256 priceWei);
    event Captured(uint256 proceeds);
    event HeldReleased(address indexed to);

    IPool public immutable pool;
    FeeSplit public immutable feeSplit;
    address public immutable sponsor;
    uint256 public immutable capWei;
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
    bool public atFloor;

    constructor(
        address pool_,
        address feeSplit_,
        address sponsor_,
        uint256 capWei_,
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
        if (capWei_ == 0 || floorWei_ == 0 || floorWei_ > parkedPriceWei_ || decayWeiPerPull_ == 0) revert BadTerms();
        pool = IPool(pool_);
        feeSplit = FeeSplit(payable(feeSplit_));
        sponsor = sponsor_;
        capWei = capWei_;
        collection = collection_;
        tokenId = tokenId_;
        parkedPriceWei = parkedPriceWei_;
        floorWei = floorWei_;
        decayWeiPerPull = decayWeiPerPull_;
        reclaimAfter = reclaimAfter_;
    }

    /// @notice Records the pool listing of this deal and locks `feeSplit`. Owner only, once, after
    ///         `Pool.registerForeign` named this contract as the controller and `feeSplit` named it as
    ///         its prize with this contract's `sponsor` and `capWei` (`TermsMismatch`).
    function start(uint256 listingId_) external {
        _requireOwner();
        if (listingId != 0) revert AlreadyStarted();
        if (feeSplit.sponsor() != sponsor || feeSplit.capWei() != capWei) revert TermsMismatch();
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
        feeSplit.lock();
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

    /// @notice Parked while the sponsor has not been paid `capWei`, Hot after.
    function phase() public view returns (Phase) {
        return feeSplit.paidWei() < capWei ? Phase.Parked : Phase.Hot;
    }

    /// @notice Lowers the listing price to `max(floorWei, parkedPriceWei - decayWeiPerPull * pullsSinceHot)`
    ///         when that is at least 1 percent below the current price, or the floor itself. A target
    ///         below `floorWei * 102 / 100` becomes `floorWei`. Does nothing in Parked. A pool revert with
    ///         `FwaBusy`, `ProbCapExceeded`, `ListingNotActive` or `RepriceTooSoon` leaves the price
    ///         unchanged and is retried by the next call. `RepriceTooSmall` for a step to `floorWei`
    ///         means the price is within 1 percent of the floor: it is final and sets `atFloor`.
    function tick() external {
        if (atFloor || !active() || phase() != Phase.Hot) return;
        uint64 pulls = pool.grail().pulls;
        if (!hotStarted) {
            hotStarted = true;
            hotFromPull = pulls;
        }
        uint256 drop = decayWeiPerPull * (pulls - hotFromPull);
        uint256 next = drop >= parkedPriceWei - floorWei ? floorWei : parkedPriceWei - drop;
        if (next * 100 < floorWei * 102) next = floorWei;
        (, uint256 current) = _entry();
        if (next >= current) return;
        if (next != floorWei && next * 100 > current * 99) return;
        try pool.repriceForeign(listingId, next) {
            emit Repriced(next);
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            if (sel == IPoolTypes.RepriceTooSmall.selector && next == floorWei) {
                atFloor = true;
            } else if (
                sel != IPoolTypes.FwaBusy.selector && sel != IPoolTypes.ProbCapExceeded.selector
                    && sel != IPoolTypes.ListingNotActive.selector && sel != IPoolTypes.RepriceTooSoon.selector
                    && sel != IPoolTypes.RepriceTooSmall.selector
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
        _unlock();
    }

    /// @notice Pool callback with the capture proceeds. Marks the deal captured, unlocks `feeSplit` and
    ///         adds the value to the pool's GRAIL fund. Reverts `UnknownEntry` for another listing.
    function onForeignCapture(uint256 listingId_, uint256, uint256) external payable {
        if (msg.sender != address(pool)) revert NotPool();
        if (listingId_ != listingId) revert UnknownEntry();
        captured = true;
        _unlock();
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
        _unlock();
    }

    /// @notice Sends the token to `sponsor` in Parked or to the owner in Hot when this contract holds
    ///         it, which is the case after the pool exported it here. Sponsor or owner only. Unlocks
    ///         `feeSplit`.
    function releaseHeld() external {
        address owner = feeSplit.owner();
        if (msg.sender != sponsor && msg.sender != owner) revert NotParty();
        address to = phase() == Phase.Parked ? sponsor : owner;
        IERC721(collection).transferFrom(address(this), to, tokenId);
        _unlock();
        emit HeldReleased(to);
    }

    /// @notice Accepts the token of this deal from the pool's export.
    function onERC721Received(address, address, uint256 id, bytes calldata) external view returns (bytes4) {
        if (msg.sender != collection || id != tokenId) revert WrongToken();
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @dev Unlocks `feeSplit` when this contract is its prize.
    function _unlock() private {
        if (feeSplit.prize() == address(this)) feeSplit.unlock();
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
