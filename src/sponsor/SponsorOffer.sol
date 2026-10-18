// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IForeignController} from "../interfaces/IForeignController.sol";
import {IPool, IPoolTypes} from "../interfaces/IPool.sol";

/// @notice Standing offer to list lent ERC-721 tokens as foreign prizes on the pool (docs/SPONSOR.md).
/// @dev This contract is the pool's registrar, the controller of every listing it registers and the Shapes
///      mint fee recipient. `take` pulls a token from its owner and lists it at the parked price. Mint fees
///      that arrive in `receive` credit the sponsors in deal order, each up to its snapshot `capWei`, and
///      the remainder credits `owner`. A deal is Parked while `paidWei < capWei` and Hot after. A Hot
///      listing decays toward `floorWei` by `decayWeiPerPull` per settled pull, applied by `tick`.
///      Terms are stored per collection. A deal copies the terms at take time.
contract SponsorOffer is IForeignController {
    enum Phase {
        Parked,
        Hot
    }

    /// @dev `maxOpen` bounds the deals of the collection that are unpaid and active at once.
    struct Terms {
        uint256 parkedPriceWei;
        uint256 floorWei;
        uint256 decayWeiPerPull;
        uint256 reclaimDelay;
        uint256 capWei;
        uint8 maxOpen;
        bool enabled;
    }

    /// @dev `capWei`, `floorWei`, `decayWeiPerPull` and `parkedPriceWei` are the terms at take time.
    struct Deal {
        address sponsor;
        address collection;
        uint256 tokenId;
        uint256 listingId;
        uint256 capWei;
        uint256 paidWei;
        uint256 takenAt;
        uint256 reclaimAfter;
        uint64 listedAtPull;
        uint64 hotFromPull;
        bool hotStarted;
        bool captured;
        bool released;
        bool atFloor;
        uint256 floorWei;
        uint256 decayWeiPerPull;
        uint256 parkedPriceWei;
    }

    struct QueueItem {
        uint256 dealId;
        address sponsor;
        uint256 remainingWei;
    }

    error NotOwner();
    error NotPool();
    error NotSponsor();
    error NotParty();
    error ZeroAddress();
    error BadTerms();
    error NotEnabled();
    error TooManyOpen();
    error UnknownDeal();
    error UnknownEntry();
    error DealClosed();
    error WrongPhase();
    error TooEarly(uint256 reclaimAfter);
    error NotListed();
    error NotUnlisted();
    error WrongDestination();
    error WrongToken();
    error NothingToWithdraw();

    event TermsSet(address indexed collection, Terms terms);
    event Taken(
        uint256 indexed dealId, address indexed sponsor, address indexed collection, uint256 tokenId, uint256 listingId
    );
    event Paid(uint256 indexed dealId, uint256 amountWei);
    event Repriced(uint256 indexed dealId, uint256 priceWei);
    event Captured(uint256 indexed dealId, uint256 proceedsWei);
    event Reclaimed(uint256 indexed dealId);
    event HeldReleased(uint256 indexed dealId, address indexed to);
    event Withdrawn(address indexed to, uint256 amountWei);

    /// @dev Foreign listing capacity of the pool.
    uint256 internal constant POOL_FOREIGN_CAP = 8;

    IPool public immutable pool;
    /// @notice Shapes collection whose mint fees this contract receives. Fees arrive through `receive`.
    address public immutable shapes;
    address public immutable owner;

    /// @notice Credit of an address from fee routing, paid by `withdraw`.
    mapping(address => uint256) public balance;
    /// @notice Index of the first deal that can still be paid. Every earlier deal is paid or closed.
    uint256 public queueHead;

    Deal[] private _deals;
    mapping(address => Terms) private _terms;
    /// @dev Deal id plus one, by listing id.
    mapping(uint256 => uint256) private _dealByListing;
    /// @dev Latest deal id plus one, by collection and token id.
    mapping(address => mapping(uint256 => uint256)) private _latestDeal;

    constructor(address pool_, address shapes_, address owner_) {
        if (pool_ == address(0) || shapes_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        pool = IPool(pool_);
        shapes = shapes_;
        owner = owner_;
    }

    // ------------------------------------------------------------------ terms

    /// @notice Sets the terms of `collection`. Owner only. Live deals keep the terms they were taken with.
    ///         Requires `parkedPriceWei > floorWei > 0`, `decayWeiPerPull > 0`, `capWei > 0` and `maxOpen`
    ///         from 1 to 8.
    function setTerms(address collection, Terms calldata t) external {
        if (msg.sender != owner) revert NotOwner();
        if (collection == address(0)) revert ZeroAddress();
        if (
            t.floorWei == 0 || t.parkedPriceWei <= t.floorWei || t.decayWeiPerPull == 0 || t.capWei == 0
                || t.maxOpen == 0 || t.maxOpen > POOL_FOREIGN_CAP
        ) revert BadTerms();
        _terms[collection] = t;
        emit TermsSet(collection, t);
    }

    function terms(address collection) external view returns (Terms memory) {
        return _terms[collection];
    }

    // ------------------------------------------------------------------ take

    /// @notice Pulls `tokenId` of `collection` from the caller, lists it on the pool at the parked price and
    ///         opens a deal that is paid from mint fees after the deals ahead of it. Requires the
    ///         collection to be enabled, fewer than `maxOpen` open deals of the collection, this contract
    ///         as the pool's registrar, room in the pool's foreign listings, and the caller to own the
    ///         token and have approved this contract for it.
    function take(address collection, uint256 tokenId) external returns (uint256 dealId) {
        Terms memory t = _terms[collection];
        if (!t.enabled) revert NotEnabled();
        if (_openCount(collection, pool.foreignListings()) >= t.maxOpen) revert TooManyOpen();
        IERC721(collection).transferFrom(msg.sender, address(this), tokenId);
        IERC721(collection).approve(address(pool), tokenId);
        pool.registerForeign(collection, tokenId, address(this), t.parkedPriceWei);
        uint256 listingId = _listingIdOf(collection, tokenId);

        dealId = _deals.length;
        _deals.push();
        Deal storage d = _deals[dealId];
        d.sponsor = msg.sender;
        d.collection = collection;
        d.tokenId = tokenId;
        d.listingId = listingId;
        d.capWei = t.capWei;
        d.takenAt = block.timestamp;
        d.reclaimAfter = block.timestamp + t.reclaimDelay;
        d.listedAtPull = pool.grail().pulls;
        d.floorWei = t.floorWei;
        d.decayWeiPerPull = t.decayWeiPerPull;
        d.parkedPriceWei = t.parkedPriceWei;
        _dealByListing[listingId] = dealId + 1;
        _latestDeal[collection][tokenId] = dealId + 1;
        emit Taken(dealId, msg.sender, collection, tokenId, listingId);
    }

    /// @notice True when `take(collection, tokenId)` by `who` can succeed in the current state.
    function canTake(address collection, uint256 tokenId, address who) external view returns (bool) {
        Terms memory t = _terms[collection];
        if (!t.enabled || pool.registrar() != address(this)) return false;
        IPoolTypes.ForeignListing[] memory all = pool.foreignListings();
        if (all.length >= POOL_FOREIGN_CAP || _openCount(collection, all) >= t.maxOpen) return false;
        IERC721 nft = IERC721(collection);
        try nft.ownerOf(tokenId) returns (address holder) {
            if (holder != who) return false;
        } catch {
            return false;
        }
        return nft.getApproved(tokenId) == address(this) || nft.isApprovedForAll(who, address(this));
    }

    // ------------------------------------------------------------------ fees

    /// @notice Credits mint fees. Walks the deals from `queueHead`: each deal that is active and below its cap
    ///         receives up to its remaining cap, in deal order, and the rest credits `owner`. `queueHead`
    ///         moves past every leading deal that is paid or closed, so the walk covers the open deals
    ///         and the closed deals between them.
    receive() external payable {
        uint256 left = msg.value;
        uint256 n = _deals.length;
        uint256 head = queueHead;
        if (left != 0 && head < n) {
            IPoolTypes.ForeignListing[] memory all = pool.foreignListings();
            uint256 newHead = head;
            bool leading = true;
            for (uint256 i = head; i < n && left != 0; ++i) {
                Deal storage d = _deals[i];
                uint256 room = d.capWei - d.paidWei;
                bool live = room != 0 && _live(d, all);
                if (live) {
                    uint256 pay = left < room ? left : room;
                    d.paidWei += pay;
                    balance[d.sponsor] += pay;
                    left -= pay;
                    emit Paid(i, pay);
                }
                if (leading && (!live || d.paidWei == d.capWei)) newHead = i + 1;
                else leading = false;
            }
            if (newHead != head) queueHead = newHead;
        }
        balance[owner] += left;
    }

    /// @notice Pays the caller its credit.
    function withdraw() external {
        uint256 amount = balance[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        balance[msg.sender] = 0;
        emit Withdrawn(msg.sender, amount);
        SafeTransferLib.safeTransferETH(msg.sender, amount);
    }

    // ------------------------------------------------------------------ views

    function deals() external view returns (Deal[] memory) {
        return _deals;
    }

    function dealCount() external view returns (uint256) {
        return _deals.length;
    }

    function deal(uint256 dealId) external view returns (Deal memory) {
        return _dealAt(dealId);
    }

    /// @notice The active deals below their cap in payment order, with the remaining cap of each.
    function queue() external view returns (QueueItem[] memory items) {
        IPoolTypes.ForeignListing[] memory all = pool.foreignListings();
        uint256 n = _deals.length;
        uint256 count;
        for (uint256 i = queueHead; i < n; ++i) {
            if (_deals[i].paidWei < _deals[i].capWei && _live(_deals[i], all)) ++count;
        }
        items = new QueueItem[](count);
        uint256 k;
        for (uint256 i = queueHead; i < n; ++i) {
            Deal storage d = _deals[i];
            if (d.paidWei < d.capWei && _live(d, all)) items[k++] = QueueItem(i, d.sponsor, d.capWei - d.paidWei);
        }
    }

    /// @notice Sum of the remaining caps ahead of a deal taken now. The fee queue is shared by every
    ///         collection, so the value is the same for each `collection`.
    function expectedWaitWei(address) external view returns (uint256 wei_) {
        IPoolTypes.ForeignListing[] memory all = pool.foreignListings();
        uint256 n = _deals.length;
        for (uint256 i = queueHead; i < n; ++i) {
            Deal storage d = _deals[i];
            if (_live(d, all)) wei_ += d.capWei - d.paidWei;
        }
    }

    /// @notice Parked while the sponsor has been paid less than `capWei`, Hot after.
    function phase(uint256 dealId) external view returns (Phase) {
        return _phase(_dealAt(dealId));
    }

    /// @notice True while the deal is not captured or released and the pool entry exists with a nonzero price.
    function active(uint256 dealId) external view returns (bool) {
        return _live(_dealAt(dealId), pool.foreignListings());
    }

    // ------------------------------------------------------------------ deal lifecycle

    /// @notice Lowers the listing price to `max(floorWei, parkedPriceWei - decayWeiPerPull * pullsSinceHot)`
    ///         when that is at least 1 percent below the current price, or the floor itself. A target
    ///         below `floorWei * 102 / 100` becomes `floorWei`. Does nothing in Parked. A pool revert with
    ///         `FwaBusy`, `ProbCapExceeded`, `RepriceTooSoon`, `RepriceTooSmall` or `ListingNotActive` leaves
    ///         the price unchanged and the next call retries. `RepriceTooSmall` for a step to `floorWei`
    ///         means the price is within 1 percent of the floor: it sets `atFloor` and ends the decay.
    function tick(uint256 dealId) external {
        Deal storage d = _dealAt(dealId);
        if (d.atFloor || _phase(d) != Phase.Hot) return;
        (bool found, uint256 current) = _entry(d.listingId);
        if (!found || current == 0 || d.captured || d.released) return;
        uint64 pulls = pool.grail().pulls;
        if (!d.hotStarted) {
            d.hotStarted = true;
            d.hotFromPull = pulls;
        }
        uint256 floorWei = d.floorWei;
        uint256 drop = d.decayWeiPerPull * (pulls - d.hotFromPull);
        uint256 next = drop >= d.parkedPriceWei - floorWei ? floorWei : d.parkedPriceWei - drop;
        if (next * 100 < floorWei * 102) next = floorWei;
        if (next >= current) return;
        if (next != floorWei && next * 100 > current * 99) return;
        try pool.repriceForeign(d.listingId, next) {
            emit Repriced(dealId, next);
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            if (sel == IPoolTypes.RepriceTooSmall.selector && next == floorWei) {
                d.atFloor = true;
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
    ///         deal is active.
    function reclaim(uint256 dealId) external {
        Deal storage d = _dealAt(dealId);
        if (msg.sender != d.sponsor) revert NotSponsor();
        if (!_live(d, pool.foreignListings())) revert NotListed();
        if (_phase(d) != Phase.Parked) revert WrongPhase();
        if (block.timestamp < d.reclaimAfter) revert TooEarly(d.reclaimAfter);
        d.released = true;
        pool.withdrawForeign(d.listingId, d.sponsor);
        emit Reclaimed(dealId);
    }

    /// @notice Pool callback with the capture proceeds. Marks the deal captured and adds the value to the
    ///         pool's GRAIL fund. Reverts `UnknownEntry` for a listing that has no deal.
    function onForeignCapture(uint256 listingId, uint256, uint256) external payable {
        if (msg.sender != address(pool)) revert NotPool();
        uint256 idPlusOne = _dealByListing[listingId];
        if (idPlusOne == 0) revert UnknownEntry();
        _deals[idPlusOne - 1].captured = true;
        emit Captured(idPlusOne - 1, msg.value);
        if (msg.value != 0) pool.fundGrail{value: msg.value}();
    }

    /// @notice Sends the token this contract holds to the sponsor in Parked or to `owner` in Hot. The pool's
    ///         `exportStep` sends the token of a listing to its controller, so after an exit the token
    ///         sits here until this call. Sponsor or owner only.
    function releaseHeld(uint256 dealId) external {
        Deal storage d = _dealAt(dealId);
        if (msg.sender != d.sponsor && msg.sender != owner) revert NotParty();
        if (d.captured || d.released) revert DealClosed();
        address to = _phase(d) == Phase.Parked ? d.sponsor : owner;
        d.released = true;
        IERC721(d.collection).transferFrom(address(this), to, d.tokenId);
        emit HeldReleased(dealId, to);
    }

    /// @notice Withdraws the token to `to` after a refunded delivery left the pool entry unlisted. Owner
    ///         only. In Parked the token belongs to the sponsor, so `to` must be the sponsor.
    function rescue(uint256 dealId, address to) external {
        if (msg.sender != owner) revert NotOwner();
        Deal storage d = _dealAt(dealId);
        (bool found, uint256 notional) = _entry(d.listingId);
        if (d.captured || d.released || !found || notional != 0) revert NotUnlisted();
        if (_phase(d) == Phase.Parked && to != d.sponsor) revert WrongDestination();
        d.released = true;
        pool.withdrawForeign(d.listingId, to);
        emit HeldReleased(dealId, to);
    }

    /// @notice Accepts a token of a deal that is not captured or released. Reverts `WrongToken` otherwise.
    function onERC721Received(address, address, uint256 id, bytes calldata) external view returns (bytes4) {
        uint256 idPlusOne = _latestDeal[msg.sender][id];
        if (idPlusOne == 0 || _deals[idPlusOne - 1].captured || _deals[idPlusOne - 1].released) revert WrongToken();
        return IERC721Receiver.onERC721Received.selector;
    }

    // ------------------------------------------------------------------ internals

    function _dealAt(uint256 dealId) private view returns (Deal storage) {
        if (dealId >= _deals.length) revert UnknownDeal();
        return _deals[dealId];
    }

    function _phase(Deal storage d) private view returns (Phase) {
        return d.paidWei < d.capWei ? Phase.Parked : Phase.Hot;
    }

    /// @dev Not captured, not released, and the pool entry exists with a nonzero price.
    function _live(Deal storage d, IPoolTypes.ForeignListing[] memory all) private view returns (bool) {
        if (d.captured || d.released) return false;
        for (uint256 i; i < all.length; ++i) {
            if (all[i].listingId == d.listingId) return all[i].notional != 0;
        }
        return false;
    }

    /// @dev Deals of `collection` that are below their cap and live. Every such deal is at or after `queueHead`.
    function _openCount(address collection, IPoolTypes.ForeignListing[] memory all) private view returns (uint256 c) {
        uint256 n = _deals.length;
        for (uint256 i = queueHead; i < n; ++i) {
            Deal storage d = _deals[i];
            if (d.collection == collection && d.paidWei < d.capWei && _live(d, all)) ++c;
        }
    }

    function _entry(uint256 listingId) private view returns (bool found, uint256 notional) {
        IPoolTypes.ForeignListing[] memory all = pool.foreignListings();
        for (uint256 i; i < all.length; ++i) {
            if (all[i].listingId == listingId) return (true, all[i].notional);
        }
    }

    function _listingIdOf(address collection, uint256 tokenId) private view returns (uint256 id) {
        IPoolTypes.ForeignListing[] memory all = pool.foreignListings();
        for (uint256 i; i < all.length; ++i) {
            if (all[i].controller == address(this) && all[i].collection == collection && all[i].tokenId == tokenId) {
                id = all[i].listingId;
            }
        }
        if (id == 0) revert UnknownEntry();
    }
}
