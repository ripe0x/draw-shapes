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
///      owner for the rest. Both parties withdraw their own balance. No payment is pushed.
contract FeeSplit {
    error NotOwner();
    error ZeroAddress();
    error DealLocked();
    error NothingToWithdraw();

    event Routed(uint256 sponsorWei, uint256 ownerWei);
    event PrizeSet(address indexed prize);
    event SponsorSet(address indexed sponsor, uint256 capWei);
    event Withdrawn(address indexed to, uint256 amountWei);

    address public immutable owner;
    address public sponsor;
    uint256 public capWei;
    uint256 public paidWei;
    address public prize;
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

    /// @notice Sets the prize contract whose `active()` gates sponsor payments. Owner only, while
    ///         `paidWei == 0` and the current prize is not active.
    function setPrize(address prize_) external {
        _requireOwner();
        if (paidWei != 0 || _prizeActive()) revert DealLocked();
        prize = prize_;
        emit PrizeSet(prize_);
    }

    /// @notice Sets the sponsor and the cap in wei. Owner only, while `paidWei == 0` and the current
    ///         prize is not active.
    function setSponsor(address sponsor_, uint256 capWei_) external {
        _requireOwner();
        if (sponsor_ == address(0)) revert ZeroAddress();
        if (paidWei != 0 || _prizeActive()) revert DealLocked();
        sponsor = sponsor_;
        capWei = capWei_;
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
