// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {PricingLib} from "./lib/PricingLib.sol";

/// @title Pool
/// @notice Depositors hold nontransferable shares of ordinary NAV. ETH held by the pool is
///         accounted in buckets: `cash`, `backing`, `receivable`, `claims`, `maintenance` and, per
///         GRAIL track, `grail[t].bucket` and `grail[t].backing`.
/// @dev Ordinary NAV = `cash + backing + receivable - claims`. GRAIL buckets and GRAIL backing are
///      outside ordinary NAV. A deposit routes an entry contribution to the two GRAIL buckets and
///      mints shares for the remainder at NAV before the deposit. A withdrawal burns shares and
///      pays `min(claim, cash)` at once. The remainder is booked in `claims` and appended to
///      `claimQueue`, which is paid in request order from `cash`.
///
///      `claims` is the unpaid part of withdrawn shares. It reduces NAV and is paid from `cash`
///      as `cash` is replenished by deposits and by backing turning into ETH.
///
///      Invariant I1: `address(this).balance >= cash + maintenance + grail[0].bucket +
///      grail[1].bucket`. ETH received outside the accounted paths raises the balance and stays
///      unaccounted, so I1 is an inequality.
///
///      Tracks are indexed `MINOR = 0` and `MAJOR = 1`. Share, claim and bucket amounts are in wei.
contract Pool is ReentrancyGuard {
    // ------------------------------------------------------------------ types

    enum Lifecycle {
        Opening,
        Live,
        Exiting,
        Exported
    }

    struct FeeSplit {
        uint16 premiumBps;
        uint16 maintenanceBps;
        uint16 feedBps;
        uint16 minorShareBps;
    }

    struct EntryCurve {
        uint32 baseBps;
        uint32 slopeBps;
        uint32 capBps;
        uint128 referenceWei;
    }

    struct GrailParams {
        uint256 targetWei;
        uint256 stepWei;
        uint256 listBps;
        uint256 decayWeiPerPull;
        uint256 floorWei;
    }

    struct Grail {
        uint256 bucket;
        uint256 packId;
        uint256 backing;
        uint256 notional;
        uint256 targetWei;
        uint256 stepWei;
        uint256 listBps;
        uint256 decayWeiPerPull;
        uint256 floorWei;
        uint256 pullsSinceList;
    }

    struct Claim {
        address to;
        uint64 requestedAt;
        uint256 amount;
    }

    struct Params {
        address shapes;
        address drawPacks;
        address fwaFactory;
        address admin;
        PricingLib.MixRow[] mix;
        FeeSplit feeSplit;
        GrailParams minor;
        GrailParams major;
        uint256 navCap;
        EntryCurve curve;
        uint256 rotateInterval;
        uint256 openingDeadline;
    }

    // ------------------------------------------------------------------ errors

    error ZeroAddress();
    error ZeroAmount();
    error FeeSplitTooHigh();
    error MinorShareTooHigh();
    error CurveCapTooHigh();
    error CurveReferenceZero();
    error ListBpsOutOfRange();
    error NotAdmin();
    error DepositsPaused();
    error NavCapReached();
    error PoolExiting();
    error ZeroShares();
    error InsufficientShares();
    error ClaimNotDue();

    // ------------------------------------------------------------------ events

    event Deposited(address indexed to, uint256 value, uint256 contribution, uint256 shares);
    event Withdrawn(address indexed from, uint256 shares, uint256 paidNow, uint256 enqueued);
    event ClaimPaid(address indexed to, uint256 amount);

    // ------------------------------------------------------------------ constants and immutables

    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_CLAIM_ITEMS = 20;
    uint256 internal constant MINOR = 0;
    uint256 internal constant MAJOR = 1;
    uint256 internal constant MAX_FEE_SPLIT_BPS = 1_000;
    uint256 internal constant MAX_CURVE_CAP_BPS = 2_500;

    address public immutable shapes;
    address public immutable drawPacks;
    address public immutable fwaFactory;

    // ------------------------------------------------------------------ storage

    address public admin;
    Lifecycle public lifecycle;
    bool public pullsPaused;
    bool public depositsPaused;

    uint256 public cash;
    uint256 public backing;
    uint256 public receivable;
    uint256 public claims;
    uint256 public maintenance;
    Grail[2] public grail;

    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    Claim[] public claimQueue;
    uint256 public claimHead;

    PricingLib.MixRow[] internal _mix;
    FeeSplit public feeSplit;
    EntryCurve public curve;
    uint256 public navCap;
    uint256 public rotateInterval;
    uint256 public openingDeadline;

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor(Params memory p) {
        if (p.shapes == address(0) || p.drawPacks == address(0) || p.fwaFactory == address(0) || p.admin == address(0))
        {
            revert ZeroAddress();
        }
        if (uint256(p.feeSplit.premiumBps) + p.feeSplit.maintenanceBps + p.feeSplit.feedBps > MAX_FEE_SPLIT_BPS) {
            revert FeeSplitTooHigh();
        }
        if (p.feeSplit.minorShareBps > BPS) revert MinorShareTooHigh();
        if (p.curve.capBps > MAX_CURVE_CAP_BPS) revert CurveCapTooHigh();
        if (p.curve.referenceWei == 0) revert CurveReferenceZero();

        shapes = p.shapes;
        drawPacks = p.drawPacks;
        fwaFactory = p.fwaFactory;
        admin = p.admin;
        feeSplit = p.feeSplit;
        curve = p.curve;
        navCap = p.navCap;
        rotateInterval = p.rotateInterval;
        openingDeadline = p.openingDeadline;

        _initGrail(MINOR, p.minor);
        _initGrail(MAJOR, p.major);
        _setMix(p.mix);
    }

    // ------------------------------------------------------------------ views

    /// @notice Ordinary NAV: `cash + backing + receivable - claims`.
    function nav() public view returns (uint256) {
        return cash + backing + receivable - claims;
    }

    function mixLength() external view returns (uint256) {
        return _mix.length;
    }

    // ------------------------------------------------------------------ depositor paths

    /// @notice Deposits `msg.value` for shares at ordinary NAV, net of the entry contribution.
    function deposit() external payable nonReentrant {
        _deposit(msg.sender, msg.value);
    }

    /// @notice Burns `shares` and pays their claim at ordinary NAV. Pays `min(claim, cash)` now and
    ///         queues the remainder in `claimQueue`.
    function withdraw(uint256 shares) external nonReentrant {
        if (shares == 0) revert ZeroAmount();
        uint256 balance = sharesOf[msg.sender];
        if (shares > balance) revert InsufficientShares();

        uint256 supply = totalShares;
        uint256 claim = PricingLib.claimFor(shares, nav(), supply);
        sharesOf[msg.sender] = balance - shares;
        totalShares = supply - shares;

        uint256 available = cash;
        uint256 paidNow = claim < available ? claim : available;
        uint256 remainder = claim - paidNow;
        cash = available - paidNow;
        if (remainder != 0) {
            claims += remainder;
            claimQueue.push(Claim(msg.sender, uint64(block.timestamp), remainder));
        }
        emit Withdrawn(msg.sender, shares, paidNow, remainder);
        if (paidNow != 0) SafeTransferLib.safeTransferETH(msg.sender, paidNow);
    }

    /// @notice Pays queued claims from `cash` in request order once the head claim is at least
    ///         `rotateInterval` old. Does nothing when the queue is empty.
    function liquidate() external nonReentrant {
        uint256 head = claimHead;
        if (head == claimQueue.length) return;
        if (block.timestamp < claimQueue[head].requestedAt + rotateInterval) revert ClaimNotDue();
        _payClaims(MAX_CLAIM_ITEMS);
    }

    /// @notice Accepts ETH from Shapes redemptions and FWA proceeds. The ETH is booked by the
    ///         function that triggered the transfer.
    receive() external payable {}

    // ------------------------------------------------------------------ internal

    /// @dev Mints shares to `to` for `value`. The entry contribution goes to the GRAIL buckets,
    ///      split by `minorShareBps`. Shares are priced on NAV before the deposit.
    function _deposit(address to, uint256 value) internal {
        if (depositsPaused) revert DepositsPaused();
        if (lifecycle >= Lifecycle.Exiting) revert PoolExiting();
        if (value == 0) revert ZeroAmount();
        uint256 currentNav = nav();
        if (currentNav >= navCap) revert NavCapReached();

        EntryCurve memory c = curve;
        uint256 contribution = PricingLib.entryContribution(
            value, PricingLib.entryCurveBps(currentNav, c.baseBps, c.slopeBps, c.capBps, c.referenceWei)
        );
        uint256 net = value - contribution;
        uint256 shares = PricingLib.sharesFor(net, currentNav, totalShares);
        if (shares == 0) revert ZeroShares();

        uint256 minorPart = contribution * feeSplit.minorShareBps / BPS;
        grail[MINOR].bucket += minorPart;
        grail[MAJOR].bucket += contribution - minorPart;
        cash += net;
        totalShares += shares;
        sharesOf[to] += shares;
        emit Deposited(to, value, contribution, shares);
    }

    /// @dev Pays claims from `cash` starting at `claimHead`, at most `maxItems` queue entries. A
    ///      partly paid head claim keeps its place with a reduced `amount`. Recipients are paid
    ///      with `forceSafeTransferETH`, so a recipient that rejects ETH cannot stall the queue.
    function _payClaims(uint256 maxItems) internal {
        uint256 head = claimHead;
        uint256 end = claimQueue.length;
        uint256 available = cash;
        uint256 paidTotal;
        for (uint256 n; n < maxItems && head < end && available != 0; ++n) {
            Claim storage c = claimQueue[head];
            uint256 amount = c.amount;
            uint256 pay = amount < available ? amount : available;
            available -= pay;
            paidTotal += pay;
            if (pay == amount) {
                ++head;
            } else {
                c.amount = amount - pay;
            }
            emit ClaimPaid(c.to, pay);
            SafeTransferLib.forceSafeTransferETH(c.to, pay);
        }
        claimHead = head;
        cash = available;
        claims -= paidTotal;
    }

    function _initGrail(uint256 track, GrailParams memory g) internal {
        if (g.listBps == 0 || g.listBps > BPS) revert ListBpsOutOfRange();
        Grail storage t = grail[track];
        t.targetWei = g.targetWei;
        t.stepWei = g.stepWei;
        t.listBps = g.listBps;
        t.decayWeiPerPull = g.decayWeiPerPull;
        t.floorWei = g.floorWei;
    }

    /// @dev Replaces the mix table. Each row must have rungs inside the Shapes ladder.
    function _setMix(PricingLib.MixRow[] memory rows) internal {
        delete _mix;
        for (uint256 i; i < rows.length; ++i) {
            PricingLib.rowBacking(rows[i]);
            _mix.push();
            PricingLib.MixRow storage row = _mix[i];
            row.shareBps = rows[i].shareBps;
            for (uint256 j; j < rows[i].rungs.length; ++j) {
                row.rungs.push(rows[i].rungs[j]);
            }
        }
    }
}
