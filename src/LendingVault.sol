// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import { ERC20 } from "lib/solmate/src/tokens/ERC20.sol";
import { SafeTransferLib } from "lib/solmate/src/utils/SafeTransferLib.sol";
import { ReentrancyGuard } from "lib/solmate/src/utils/ReentrancyGuard.sol";
import { Owned } from "lib/solmate/src/auth/Owned.sol";
import { ISunToken } from "./interfaces/ISunToken.sol";

/**
 * Zero-coupon bond with a performance-based premium, against a single real-world asset.
 *
 * Lenders subscribe EURC 1:1 for claim tokens. The client draws the principal down, builds the
 * asset, and once it is live the term starts. Measured profit is pushed on-chain by the oracle
 * adapter and accrues as premium. The client repays principal + premium in one payment at
 * maturity; lenders then burn claim tokens to redeem.
 *
 * The obligation is unsecured: the principal becomes physical hardware that cannot be escrowed.
 * The contract records the obligation, freezes it at maturity, and distributes whatever was
 * actually repaid pro-rata, so a shortfall is a shared haircut rather than a race.
 *
 * Implements docs/lending-vault-spec.md. Requirement tags (R-n, I-n) refer to that document.
 */
contract LendingVault is Owned, ReentrancyGuard {
    using SafeTransferLib for ERC20;

    enum Phase {
        Funding,
        Failed,
        Drawdown,
        Accruing,
        Settlement,
        Redemption,
        Default
    }

    struct Config {
        address client;
        address activator;
        address claimToken;
        uint256 tokenId;
        address collateralToken;
        uint256 principal;
        uint256 fundingWindow;
        uint256 term;
        uint256 activationWindow;
        uint256 graceWindow;
        uint256 maxRebaseDeltaRatio;
        uint256 maxStaleness;
    }

    /*//////////////////////////////////////////////////////////////
                              PARAMETERS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant BPS = 10_000;

    /// Address that draws the principal down and owes repayment
    address public immutable client;

    /// Address that attests the asset is live (spec §10.1 — resolved at deployment)
    address public immutable activator;

    ISunToken public immutable claimToken;

    uint256 public immutable tokenId;

    ERC20 public immutable collateralToken;

    /// Cached, not assumed (R-1)
    uint8 public immutable collateralDecimals;

    /// Funding target. Also the claim token supply once funding closes (R-33)
    uint256 public immutable principal;

    uint256 public immutable fundingDeadline;

    /// Duration, not a date. Starts at activate(), never settable afterwards (R-29)
    uint256 public immutable term;

    uint256 public immutable activationWindow;

    uint256 public immutable graceWindow;

    /// Max |delta| a single rebase may apply, relative to principal, in bps (R-26)
    uint256 public immutable maxRebaseDeltaRatio;

    uint256 public immutable maxStaleness;

    /*//////////////////////////////////////////////////////////////
                            RUNNING STATE
    //////////////////////////////////////////////////////////////*/

    /// Funding progress. Reaches `principal` or the raise fails
    uint256 public subscribed;

    /// Signed accumulator; `owed` floors it at read time (R-10)
    int256 public cumulativeYield;

    /// Cumulative EURC received as repayment
    uint256 public repaid;

    /// min(owed, pot) snapshotted by finalize(); the pot redemptions are paid from (R-15)
    uint256 public settled;

    /// Client overpayment, withdrawable after finalize (R-32)
    uint256 public surplus;

    uint256 public activatedAt;

    /// Zero until activation, immutable after (I-5). `owed` is constant from here (I-4)
    uint256 public maturity;

    uint256 public activationDeadline;

    uint64 public lastRebasedAt;

    address public rebaseAdapter;

    bool public drawnDown;

    bool public finalized;

    /// Recorded permanently once finalize() sees an unmet obligation
    bool public defaulted;

    Phase private _storedPhase;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Subscribed(address indexed lender, uint256 amount, uint256 subscribedTotal);
    event FundingClosed(uint256 raised, uint256 activationDeadline);
    event Refunded(address indexed lender, uint256 amount);
    event DrawnDown(address indexed to, uint256 amount);
    event Activated(uint256 activatedAt, uint256 maturity);
    event Rebased(int256 delta, uint64 updatedAt, uint256 owed);
    event Repaid(address indexed from, uint256 amount, uint256 repaidTotal);
    event Finalized(uint256 owed, uint256 repaidTotal, uint256 settled, bool defaulted);
    event Redeemed(address indexed lender, uint256 burned, uint256 received);
    event SurplusWithdrawn(address indexed to, uint256 amount);
    event RebaseAdapterChanged(address oldAdapter, address newAdapter);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error WrongPhase(Phase expected, Phase actual);
    error ZeroAmount();
    error ExceedsTarget(uint256 remaining);
    error NotClient();
    error NotActivator();
    error NotAdapter();
    error AlreadyDrawnDown();
    error NotDrawnDown();
    error AlreadyActivated();
    error AlreadyFinalized();
    error NotFinalizable();
    error AdapterFrozen();
    error PeriodAlreadySeen();
    error PeriodBeforeActivation();
    error PeriodInFuture();
    error StaleUpdate();
    error DeltaOutOfBounds();
    error InvalidConfig();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(Config memory c, address operator) Owned(operator) {
        if (
            c.principal == 0 || c.term == 0 || c.fundingWindow == 0 || c.activationWindow == 0
                || c.client == address(0) || c.activator == address(0) || c.claimToken == address(0)
                || c.collateralToken == address(0)
                || c.maxRebaseDeltaRatio == 0 || c.maxRebaseDeltaRatio > BPS
        ) revert InvalidConfig();

        client = c.client;
        activator = c.activator;
        claimToken = ISunToken(c.claimToken);
        tokenId = c.tokenId;
        collateralToken = ERC20(c.collateralToken);
        collateralDecimals = ERC20(c.collateralToken).decimals();
        principal = c.principal;
        fundingDeadline = block.timestamp + c.fundingWindow;
        term = c.term;
        activationWindow = c.activationWindow;
        graceWindow = c.graceWindow;
        maxRebaseDeltaRatio = c.maxRebaseDeltaRatio;
        maxStaleness = c.maxStaleness;

        _storedPhase = Phase.Funding;
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * Effective phase. Deadline-driven transitions are derived rather than pushed, so no vault
     * can stall because a privileged party declined to call a function (R-7).
     */
    function phase() public view returns (Phase) {
        Phase p = _storedPhase;

        if (p == Phase.Funding) {
            return block.timestamp >= fundingDeadline ? Phase.Failed : Phase.Funding;
        }

        if (p == Phase.Drawdown) {
            return block.timestamp >= activationDeadline ? Phase.Default : Phase.Drawdown;
        }

        if (p == Phase.Accruing) {
            if (block.timestamp >= maturity + graceWindow && repaid < owed()) return Phase.Default;
            if (block.timestamp >= maturity) return Phase.Settlement;
            return Phase.Accruing;
        }

        return p;
    }

    /**
     * Total obligation: principal plus accrued premium, floored at principal (R-9, R-10).
     * A performance-based premium may shrink to zero; principal is never forgiven.
     */
    function owed() public view returns (uint256) {
        int256 y = cumulativeYield;

        return y > 0 ? principal + uint256(y) : principal;
    }

    /**
     * Unmet obligation at this block (R-13)
     */
    function shortfall() external view returns (uint256) {
        uint256 o = owed();
        uint256 covered = _pot();

        return covered >= o ? 0 : o - covered;
    }

    /**
     * What `amount` claim tokens are worth. Before finalize this is the accrued claim; after
     * finalize it is what will actually be paid. Quoted for an amount rather than per token,
     * because a per-token rate is not representable without a scaling factor (R-30).
     */
    function claimValue(uint256 amount) external view returns (uint256) {
        return finalized ? (amount * settled) / principal : (amount * owed()) / principal;
    }

    function outstandingSupply() external view returns (uint256) {
        return claimToken.totalSupply(tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                                FUNDING
    //////////////////////////////////////////////////////////////*/

    /**
     * Deposit EURC and receive claim tokens 1:1. Tokens are minted here, never pre-minted to
     * the vault, so outstanding supply at funding close is exactly `principal` (R-11).
     */
    function subscribe(uint256 amount) external nonReentrant {
        _require(Phase.Funding);
        if (amount == 0) revert ZeroAmount();

        uint256 remaining = principal - subscribed;
        if (amount > remaining) revert ExceedsTarget(remaining);

        subscribed += amount;

        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        claimToken.mint(msg.sender, tokenId, amount);

        emit Subscribed(msg.sender, amount, subscribed);

        // Partial fills are not accepted; the raise fills exactly or it fails (R-33)
        if (subscribed == principal) {
            _storedPhase = Phase.Drawdown;
            activationDeadline = block.timestamp + activationWindow;

            emit FundingClosed(subscribed, activationDeadline);
        }
    }

    /**
     * Burn claim tokens for EURC 1:1 after a failed raise. No premium, no loss.
     */
    function refund(uint256 amount) external nonReentrant {
        _require(Phase.Failed);
        if (amount == 0) revert ZeroAmount();

        claimToken.burn(msg.sender, tokenId, amount);
        collateralToken.safeTransfer(msg.sender, amount);

        emit Refunded(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                           DRAWDOWN & ACTIVATION
    //////////////////////////////////////////////////////////////*/

    /**
     * Client takes the principal to build the asset. Once, capped, and never reading the
     * balance — repayments share this balance and must not be reclaimable (R-12).
     */
    function drawdown() external nonReentrant {
        _require(Phase.Drawdown);
        if (msg.sender != client) revert NotClient();
        if (drawnDown) revert AlreadyDrawnDown();

        drawnDown = true;

        collateralToken.safeTransfer(client, principal);

        emit DrawnDown(client, principal);
    }

    /**
     * Attest that the asset is live and start the term. Takes no arguments: only the start of
     * the term floats, never its length (R-29, I-12).
     */
    function activate() external {
        _require(Phase.Drawdown);
        if (msg.sender != activator) revert NotActivator();
        if (maturity != 0) revert AlreadyActivated();
        if (!drawnDown) revert NotDrawnDown();

        activatedAt = block.timestamp;
        maturity = block.timestamp + term;
        _storedPhase = Phase.Accruing;

        emit Activated(activatedAt, maturity);
    }

    /*//////////////////////////////////////////////////////////////
                            ACCRUAL & REPAYMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * Accrue measured profit into the obligation.
     *
     * Accrual stops dead at maturity (R-23, R-24): once the term is over the obligation is
     * frozen, so a fulfillment that arrives late is dropped rather than applied. Whether the
     * oracle reports the final period in time is an off-chain guarantee — the contract cannot
     * enforce timeliness, only refuse to move the debt after the window has closed.
     */
    function rebase(int256 delta, uint64 updatedAt) external {
        if (msg.sender != rebaseAdapter) revert NotAdapter();

        _require(Phase.Accruing);

        if (updatedAt <= lastRebasedAt) revert PeriodAlreadySeen();
        if (updatedAt < activatedAt) revert PeriodBeforeActivation();
        if (updatedAt > block.timestamp) revert PeriodInFuture();
        if (block.timestamp - updatedAt > maxStaleness) revert StaleUpdate();

        int256 bound = int256(principal * maxRebaseDeltaRatio / BPS);
        if (delta > bound || delta < -bound) revert DeltaOutOfBounds();

        cumulativeYield += delta;
        lastRebasedAt = updatedAt;

        emit Rebased(delta, updatedAt, owed());
    }

    /**
     * Repay the obligation. Prepayment during Accruing is allowed and does not unlock early
     * redemption (R-18). Rejected once finalized, because `settled` is fixed by then and late
     * money could not be distributed.
     */
    function repay(uint256 amount) external nonReentrant {
        if (finalized) revert AlreadyFinalized();
        if (amount == 0) revert ZeroAmount();

        Phase p = phase();
        if (p != Phase.Accruing && p != Phase.Settlement && p != Phase.Default) {
            revert WrongPhase(Phase.Settlement, p);
        }

        repaid += amount;

        collateralToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Repaid(msg.sender, amount, repaid);
    }

    /*//////////////////////////////////////////////////////////////
                          SETTLEMENT & REDEMPTION
    //////////////////////////////////////////////////////////////*/

    /**
     * Freeze the obligation and fix the pot redemptions are paid from.
     *
     * Callable by anyone once the grace window closes, and early once the obligation is fully
     * covered (R-16). Fixing a single total here is what makes a shortfall a shared haircut
     * instead of a race between holders (R-14).
     */
    function finalize() external {
        if (finalized) revert AlreadyFinalized();

        Phase p = phase();
        uint256 o = owed();
        uint256 pot = _pot();

        bool graceClosed = maturity != 0 && block.timestamp >= maturity + graceWindow;
        if (!(pot >= o || graceClosed || p == Phase.Default)) revert NotFinalizable();

        finalized = true;
        settled = o < pot ? o : pot;
        defaulted = settled < o;

        // Only an overpaying client can leave a surplus, and only when lenders are whole (R-32)
        if (settled == o && repaid > o) surplus = repaid - o;

        _storedPhase = Phase.Redemption;

        emit Finalized(o, repaid, settled, defaulted);
    }

    /**
     * Burn claim tokens and receive their pro-rata share of the settled pot.
     *
     * Division truncates, so the sum of payouts never exceeds `settled` and the last redeemer
     * is never short (R-31).
     */
    function redeem(uint256 amount) external nonReentrant {
        _require(Phase.Redemption);
        if (amount == 0) revert ZeroAmount();

        uint256 payout = (amount * settled) / principal;

        claimToken.burn(msg.sender, tokenId, amount);
        if (payout > 0) collateralToken.safeTransfer(msg.sender, payout);

        emit Redeemed(msg.sender, amount, payout);
    }

    /**
     * Return an overpayment to the client. Never touches the lenders' pot (R-32).
     */
    function withdrawSurplus() external nonReentrant {
        _require(Phase.Redemption);
        if (msg.sender != client) revert NotClient();

        uint256 amount = surplus;
        if (amount == 0) revert ZeroAmount();

        surplus = 0;

        collateralToken.safeTransfer(client, amount);

        emit SurplusWithdrawn(client, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMINISTRATION
    //////////////////////////////////////////////////////////////*/

    /**
     * Set the oracle adapter. Frozen once funding closes: after lenders commit capital nobody
     * may swap out the source of truth for what is owed to them (R-19).
     */
    function setRebaseAdapter(address adapter) external onlyOwner {
        if (_storedPhase != Phase.Funding) revert AdapterFrozen();

        address old = rebaseAdapter;
        rebaseAdapter = adapter;

        emit RebaseAdapterChanged(old, adapter);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    /**
     * EURC available to cover the obligation. Undrawn principal counts: if the vault defaults
     * before drawdown the subscription money never left, and it belongs to the lenders.
     */
    function _pot() private view returns (uint256) {
        return drawnDown ? repaid : repaid + principal;
    }

    function _require(Phase expected) private view {
        Phase actual = phase();
        if (actual != expected) revert WrongPhase(expected, actual);
    }
}
