// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @notice Active flag of a sponsored prize, read by `FeeSplit`.
interface IPrizeStatus {
    function active() external view returns (bool);
}

/// @notice Shapes mint fee recipient that splits each payment between a sponsor and the owner.
/// @dev Shapes credits mint fees to `feesOwedTo(recipient)`; `Shapes.withdrawFees(feeSplit)` sends them
///      here. Each payment credits the sponsor up to the remaining cap while the prize is active and the
///      owner for the rest. Both parties withdraw their own balance. No payment is pushed. The prize
///      locks the split when its deal starts and unlocks it at the end of the deal; the sponsor, the
///      cap and the prize cannot change while it is locked.
contract FeeSplit {
    error NotOwner();
    error ZeroAddress();
    error DealLocked();
    error Locked();
    error NotPrize();
    error NothingToWithdraw();
    error SponsorBalanceUnpaid();

    event Routed(uint256 sponsorWei, uint256 ownerWei);
    event PrizeSet(address indexed prize);
    event SponsorSet(address indexed sponsor, uint256 capWei);
    event Withdrawn(address indexed to, uint256 amountWei);
    event LockSet(bool locked);

    address public immutable owner;
    address public sponsor;
    uint256 public capWei;
    uint256 public paidWei;
    address public prize;
    bool public locked;
    uint256 public ownerBalance;
    uint256 public sponsorBalance;

    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
    }

    /// @notice Credits `sponsorBalance` up to `capWei - paidWei` while the prize is active and
    ///         `ownerBalance` for the rest of `msg.value`.
    receive() external payable {
        uint256 paid = paidWei;
        uint256 toSponsor;
        if (paid < capWei && _prizeActive()) {
            uint256 room = capWei - paid;
            toSponsor = msg.value < room ? msg.value : room;
            paidWei = paid + toSponsor;
            sponsorBalance += toSponsor;
        }
        uint256 toOwner = msg.value - toSponsor;
        ownerBalance += toOwner;
        emit Routed(toSponsor, toOwner);
    }

    /// @notice Pays the caller its balance: `ownerBalance` to the owner, `sponsorBalance` to the sponsor.
    function withdraw() external {
        uint256 amount;
        if (msg.sender == owner) {
            amount = ownerBalance;
            ownerBalance = 0;
        }
        if (msg.sender == sponsor) {
            amount += sponsorBalance;
            sponsorBalance = 0;
        }
        if (amount == 0) revert NothingToWithdraw();
        emit Withdrawn(msg.sender, amount);
        SafeTransferLib.safeTransferETH(msg.sender, amount);
    }

    /// @notice Freezes `sponsor`, `capWei` and `prize`. Called by the prize when it starts.
    function lock() external {
        if (msg.sender != prize) revert NotPrize();
        locked = true;
        emit LockSet(true);
    }

    /// @notice Releases the freeze set by `lock`. Called by the prize at the end of its deal.
    function unlock() external {
        if (msg.sender != prize) revert NotPrize();
        locked = false;
        emit LockSet(false);
    }

    /// @notice Sets the prize contract whose `active()` gates sponsor payments. Owner only, while
    ///         `paidWei == 0` (`DealLocked`) and the split is not locked (`Locked`).
    function setPrize(address prize_) external {
        _requireOwner();
        if (locked) revert Locked();
        if (paidWei != 0) revert DealLocked();
        prize = prize_;
        emit PrizeSet(prize_);
    }

    /// @notice Sets the sponsor and the cap in wei and resets `paidWei` to zero, which starts a new deal.
    ///         Owner only, while the split is not locked (`Locked`). `ownerBalance` and `sponsorBalance`
    ///         keep their values. A different sponsor needs `sponsorBalance == 0` (`SponsorBalanceUnpaid`),
    ///         so the previous sponsor's balance is withdrawn by that sponsor.
    function setSponsor(address sponsor_, uint256 capWei_) external {
        _requireOwner();
        if (sponsor_ == address(0)) revert ZeroAddress();
        if (locked) revert Locked();
        if (sponsor_ != sponsor && sponsorBalance != 0) revert SponsorBalanceUnpaid();
        sponsor = sponsor_;
        capWei = capWei_;
        paidWei = 0;
        emit SponsorSet(sponsor_, capWei_);
    }

    function _requireOwner() private view {
        if (msg.sender != owner) revert NotOwner();
    }

    /// @dev A prize that is unset or reverts counts as inactive, so a fee payment never reverts.
    function _prizeActive() private view returns (bool) {
        address p = prize;
        if (p == address(0)) return false;
        try IPrizeStatus(p).active() returns (bool a) {
            return a;
        } catch {
            return false;
        }
    }
}
