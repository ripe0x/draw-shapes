// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IForeignController} from "../interfaces/IForeignController.sol";
import {IPool, IPoolTypes} from "../interfaces/IPool.sol";

/// @title PrizeSponsorship
/// @notice One sponsor lends one NFT of `collection` as a headline prize, listed on the board at
///         `listPriceWei` from the first day, and is paid up to `capWei` from the treasury's
///         trading receipts while the prize stays unwon.
/// @dev Adapted from `SponsoredPrize` (branch `claude/next`). Changes: the prize is never parked at
///      a deterrent price (its odds are the published odds from the stake on); compensation comes
///      only from the treasury's post-founder trading receipts (`EngineTreasury.sponsorShareBps`),
///      never from Shapes mint fees; reaching `capWei` hands the prize to the game instead of
///      starting a decay.
///
///      States, in order: Unstaked, Listed (paid while `paid < capWei`), then one terminal state:
///      - Won: a player drew the prize. The NFT is the player's, the sponsor keeps what was paid and
///        the unpaid rest of `capWei` is cancelled (`owed()` is zero from the capture on).
///      - Reclaimed: from `reclaimAfter`, while unwon and short of the cap, the sponsor takes the NFT
///        back. The pool refuses the withdrawal while it holds unsettled acquisitions, so a reclaim
///        never removes a prize a pending draw may select. Payments stop.
///      - Completed: `paid` reached `capWei`. The sponsor has no further claim on the NFT or on
///        payments; the NFT stays listed and belongs to the treasury.
///      The sponsor pulls earned ETH with `claim` in every state.
///
///      The game never owes the NFT's market value. Its only obligation is the capped stream, and
///      only while the NFT is listed and unwon.
contract PrizeSponsorship is IForeignController, ReentrancyGuard {
    error NotSponsor();
    error NotPool();
    error NotTreasury();
    error BadTerms();
    error AlreadyStaked();
    error NotRegistrar();
    error UnknownEntry();
    error WrongState();
    error TooEarly(uint256 reclaimAfter);
    error AboveOwed(uint256 owed);
    error NothingToClaim();

    event Staked(uint256 indexed listingId, uint256 indexed tokenId);
    event Paid(uint256 amount, uint256 paid);
    event Claimed(uint256 amount);
    event Won(uint256 proceeds);
    event Reclaimed();
    event Completed();
    event Released(address to);

    IPool public immutable pool;
    address public immutable treasury;
    address public immutable sponsor;
    address public immutable collection;
    uint256 public immutable listPriceWei;
    uint256 public immutable capWei;
    uint256 public immutable reclaimDelay;

    uint256 public tokenId;
    uint256 public listingId;
    uint256 public stakedAt;
    uint256 public paid;
    uint256 public claimed;
    bool public won;
    bool public reclaimed;

    constructor(
        address pool_,
        address treasury_,
        address sponsor_,
        address collection_,
        uint256 listPriceWei_,
        uint256 capWei_,
        uint256 reclaimDelay_
    ) {
        if (
            pool_ == address(0) || treasury_ == address(0) || sponsor_ == address(0) || collection_ == address(0)
                || listPriceWei_ == 0 || capWei_ == 0
        ) revert BadTerms();
        pool = IPool(pool_);
        treasury = treasury_;
        sponsor = sponsor_;
        collection = collection_;
        listPriceWei = listPriceWei_;
        capWei = capWei_;
        reclaimDelay = reclaimDelay_;
    }

    /// @notice Earliest time the sponsor may reclaim. Zero before the stake.
    function reclaimAfter() public view returns (uint256) {
        return stakedAt == 0 ? 0 : stakedAt + reclaimDelay;
    }

    function completed() public view returns (bool) {
        return paid >= capWei;
    }

    /// @notice True while the prize is listed, unwon, not reclaimed and short of the cap.
    function active() public view returns (bool) {
        if (listingId == 0 || won || reclaimed || completed()) return false;
        (bool found, uint256 notional) = _entry();
        return found && notional != 0;
    }

    /// @notice Payment still due under the terms: `capWei - paid` while active, zero otherwise.
    function owed() public view returns (uint256) {
        return active() ? capWei - paid : 0;
    }

    /// @notice Pulls token `tokenId_` from the sponsor and registers it on the pool at `listPriceWei`.
    ///         Sponsor only, once. Requires this contract to be the pool's registrar and the
    ///         sponsor's approval. The pool enforces the probability cap.
    function stake(uint256 tokenId_) external nonReentrant {
        if (msg.sender != sponsor) revert NotSponsor();
        if (listingId != 0) revert AlreadyStaked();
        if (pool.registrar() != address(this)) revert NotRegistrar();
        tokenId = tokenId_;
        IERC721(collection).transferFrom(sponsor, address(this), tokenId_);
        IERC721(collection).approve(address(pool), tokenId_);
        pool.registerForeign(collection, tokenId_, address(this), listPriceWei);
        IPoolTypes.ForeignListing[] memory all = pool.foreignListings();
        for (uint256 i; i < all.length; ++i) {
            if (all[i].controller == address(this) && all[i].tokenId == tokenId_) listingId = all[i].listingId;
        }
        if (listingId == 0) revert UnknownEntry();
        stakedAt = block.timestamp;
        emit Staked(listingId, tokenId_);
    }

    /// @notice Treasury payment toward the cap. Reverts above `owed()`, so nothing is paid after a
    ///         win, a reclaim or completion.
    function pay() external payable {
        if (msg.sender != treasury) revert NotTreasury();
        uint256 due = owed();
        if (msg.value > due) revert AboveOwed(due);
        paid += msg.value;
        emit Paid(msg.value, paid);
        if (completed()) emit Completed();
    }

    /// @notice Pays the sponsor everything paid in and not yet claimed.
    function claim() external nonReentrant {
        uint256 amount = paid - claimed;
        if (amount == 0) revert NothingToClaim();
        claimed = paid;
        emit Claimed(amount);
        SafeTransferLib.safeTransferETH(sponsor, amount);
    }

    /// @notice Returns the NFT to the sponsor. Sponsor only, from `reclaimAfter`, while the prize is
    ///         listed, unwon and short of the cap. Reverts `FwaBusy` from the pool while a draw is
    ///         pending.
    function reclaim() external nonReentrant {
        if (msg.sender != sponsor) revert NotSponsor();
        if (listingId == 0 || won || reclaimed || completed()) revert WrongState();
        if (block.timestamp < reclaimAfter()) revert TooEarly(reclaimAfter());
        reclaimed = true;
        emit Reclaimed();
        pool.withdrawForeign(listingId, sponsor);
    }

    /// @notice Pool callback when a player wins the prize. Ends payments and adds the ticket proceeds
    ///         to the pool's GRAIL fund.
    function onForeignCapture(uint256 listingId_, uint256, uint256) external payable {
        if (msg.sender != address(pool)) revert NotPool();
        if (listingId_ != listingId) revert UnknownEntry();
        won = true;
        emit Won(msg.value);
        if (msg.value != 0) pool.fundGrail{value: msg.value}();
    }

    /// @notice Moves the NFT to its owner when it is not on the board: after a refunded delivery left
    ///         the pool entry unlisted, or after the pool's export sent it here. The owner is the
    ///         sponsor until completion and the treasury after. Anyone.
    function release() external nonReentrant {
        if (listingId == 0 || won) revert WrongState();
        address to = completed() ? treasury : sponsor;
        if (!completed()) reclaimed = true;
        (bool found, uint256 notional) = _entry();
        if (found) {
            if (notional != 0) revert WrongState();
            pool.withdrawForeign(listingId, to);
        } else {
            IERC721(collection).transferFrom(address(this), to, tokenId);
        }
        emit Released(to);
    }

    /// @dev The pool entry of `listingId`: whether it exists and its price (zero while unlisted).
    function _entry() internal view returns (bool found, uint256 notional) {
        IPoolTypes.ForeignListing[] memory all = pool.foreignListings();
        for (uint256 i; i < all.length; ++i) {
            if (all[i].listingId == listingId) return (true, all[i].notional);
        }
    }
}
