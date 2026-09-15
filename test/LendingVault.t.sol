// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "lib/forge-std/src/Test.sol";
import { ERC20 } from "lib/solmate/src/tokens/ERC20.sol";
import { LendingVault } from "../src/LendingVault.sol";
import { SunToken } from "../src/SunToken.sol";

contract MockEURC is ERC20("Euro Coin", "EURC", 6) {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract LendingVaultTest is Test {
    MockEURC eurc;
    SunToken claim;
    LendingVault vault;

    address operator = address(0xA0);
    address borrower = address(0xC1);
    address activator = address(0xAC);
    address adapter = address(0xAD);
    address alice = address(0xA1);
    address bob = address(0xB0);

    uint256 constant PRINCIPAL = 10_000e6;
    uint256 constant TOKEN_ID = 1;
    uint256 constant FUNDING_WINDOW = 30 days;
    uint256 constant TERM = 365 days;
    uint256 constant ACTIVATION_WINDOW = 90 days;
    uint256 constant GRACE = 14 days;
    uint256 constant MAX_REBASE_DELTA_RATIO = 1_000; // 10% of principal
    uint256 constant MAX_DELTA = PRINCIPAL * MAX_REBASE_DELTA_RATIO / 10_000;
    uint256 constant MAX_STALENESS = 7 days;

    function setUp() public {
        vm.warp(1_700_000_000);

        eurc = new MockEURC();

        // OwnerIsCreator: the collection owner is whoever deploys it
        vm.prank(operator);
        claim = new SunToken("ipfs://base");

        LendingVault.Config memory c = LendingVault.Config({
            borrower: borrower,
            activator: activator,
            claimToken: address(claim),
            tokenId: TOKEN_ID,
            collateralToken: address(eurc),
            principal: PRINCIPAL,
            fundingWindow: FUNDING_WINDOW,
            term: TERM,
            activationWindow: ACTIVATION_WINDOW,
            graceWindow: GRACE,
            maxRebaseDeltaRatio: MAX_REBASE_DELTA_RATIO,
            maxStaleness: MAX_STALENESS
        });

        vault = new LendingVault(c, operator);

        vm.startPrank(operator);
        claim.setIssuer(TOKEN_ID, address(vault), "vault-1.json");
        vault.setRebaseAdapter(adapter);
        vm.stopPrank();

        eurc.mint(alice, 1_000_000e6);
        eurc.mint(bob, 1_000_000e6);
        eurc.mint(borrower, 1_000_000e6);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _subscribe(address who, uint256 amount) internal {
        vm.startPrank(who);
        eurc.approve(address(vault), amount);
        vault.subscribe(amount);
        vm.stopPrank();
    }

    function _repay(uint256 amount) internal {
        vm.startPrank(borrower);
        eurc.approve(address(vault), amount);
        vault.repay(amount);
        vm.stopPrank();
    }

    /// Fund fully, draw down, activate.
    function _toAccruing() internal {
        _subscribe(alice, PRINCIPAL / 2);
        _subscribe(bob, PRINCIPAL / 2);

        vm.prank(borrower);
        vault.drawdown();

        vm.prank(activator);
        vault.activate();
    }

    function _rebase(int256 delta, uint256 at) internal {
        vm.prank(adapter);
        vault.rebase(delta, uint64(at));
    }

    /*//////////////////////////////////////////////////////////////
                              HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_fullLifecycle_repaidInFull() public {
        _toAccruing();

        assertEq(uint256(vault.maturity()), block.timestamp + TERM, "I-12");
        assertEq(eurc.balanceOf(borrower), 1_000_000e6 + PRINCIPAL, "drawdown paid out");

        // Accrue premium over the term
        uint256 premium;
        for (uint256 i = 1; i <= 12; i++) {
            uint256 at = vault.activatedAt() + i * 30 days;
            vm.warp(at + 1 days);
            _rebase(100e6, at);
            premium += 100e6;
        }

        assertEq(vault.owed(), PRINCIPAL + premium);

        vm.warp(vault.maturity() + 1);
        _repay(vault.owed());

        vault.finalize();
        assertFalse(vault.defaulted());
        assertEq(vault.settled(), PRINCIPAL + premium);

        uint256 aliceBefore = eurc.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(PRINCIPAL / 2);

        // Half the supply redeems half the pot: principal back plus half the premium
        assertEq(eurc.balanceOf(alice) - aliceBefore, (PRINCIPAL + premium) / 2);
        assertGt(eurc.balanceOf(alice) - aliceBefore, PRINCIPAL / 2, "made a profit");
    }

    /*//////////////////////////////////////////////////////////////
                      SHORTFALL IS SHARED, NOT RACED
    //////////////////////////////////////////////////////////////*/

    /// R-14 / I-7: an 80% recovery pays every holder 80%, regardless of redemption order.
    function test_shortfall_isSharedProRata_notFirstComeFirstServed() public {
        _toAccruing();

        vm.warp(vault.maturity() + 1);

        uint256 owed = vault.owed();
        _repay((owed * 80) / 100);

        vm.warp(vault.maturity() + GRACE + 1);
        vault.finalize();

        assertTrue(vault.defaulted(), "shortfall recorded");

        uint256 aliceBefore = eurc.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(PRINCIPAL / 2);
        uint256 alicePaid = eurc.balanceOf(alice) - aliceBefore;

        // Bob redeems last and is paid at exactly the same rate
        uint256 bobBefore = eurc.balanceOf(bob);
        vm.prank(bob);
        vault.redeem(PRINCIPAL / 2);
        uint256 bobPaid = eurc.balanceOf(bob) - bobBefore;

        assertEq(alicePaid, bobPaid, "R-14: equal haircut");
        assertEq(alicePaid, (owed * 80) / 100 / 2, "80% of a half claim");
        assertLe(alicePaid + bobPaid, vault.settled(), "I-7");
    }

    /// The v1 failure mode: first redeemer must not be able to take a full claim from a short vault.
    function test_shortfall_firstRedeemerCannotDrainTheVault() public {
        _toAccruing();

        vm.warp(vault.maturity() + 1);
        _repay((vault.owed() * 50) / 100);

        vm.warp(vault.maturity() + GRACE + 1);
        vault.finalize();

        vm.prank(alice);
        vault.redeem(PRINCIPAL / 2);

        // Half the pot must still be there for bob
        assertGe(eurc.balanceOf(address(vault)), vault.settled() / 2, "bob's share intact");

        vm.prank(bob);
        vault.redeem(PRINCIPAL / 2);
    }

    /*//////////////////////////////////////////////////////////////
                            FUNDING & REFUND
    //////////////////////////////////////////////////////////////*/

    function test_overSubscription_reverts() public {
        _subscribe(alice, PRINCIPAL - 1e6);

        vm.startPrank(bob);
        eurc.approve(address(vault), 2e6);
        vm.expectRevert(abi.encodeWithSelector(LendingVault.ExceedsTarget.selector, 1e6));
        vault.subscribe(2e6);
        vm.stopPrank();
    }

    /// R-33: a partial raise fails and refunds 1:1 rather than proceeding at a lower principal.
    function test_underFunded_failsAndRefundsOneToOne() public {
        _subscribe(alice, PRINCIPAL / 4);

        vm.warp(block.timestamp + FUNDING_WINDOW);
        assertEq(uint256(vault.phase()), uint256(LendingVault.Phase.Failed));

        vm.prank(borrower);
        vm.expectRevert();
        vault.drawdown();

        uint256 before = eurc.balanceOf(alice);
        vm.prank(alice);
        vault.refund(PRINCIPAL / 4);

        assertEq(eurc.balanceOf(alice) - before, PRINCIPAL / 4, "I-10");
        assertEq(claim.totalSupply(TOKEN_ID), 0);
    }

    function test_fundingClosesExactlyAtTarget() public {
        _subscribe(alice, PRINCIPAL / 2);
        assertEq(uint256(vault.phase()), uint256(LendingVault.Phase.Funding));

        _subscribe(bob, PRINCIPAL / 2);
        assertEq(uint256(vault.phase()), uint256(LendingVault.Phase.Drawdown));

        // I-2: supply equals principal once funding closes
        assertEq(claim.totalSupply(TOKEN_ID), PRINCIPAL);
        assertEq(claim.balanceOf(address(vault), TOKEN_ID), 0, "vault holds no claims of its own");
    }

    /*//////////////////////////////////////////////////////////////
                          DRAWDOWN PROTECTIONS
    //////////////////////////////////////////////////////////////*/

    /// R-12: drawdown runs once, and repayments sharing the balance stay out of reach.
    function test_drawdown_onceOnly_andCannotSweepRepayments() public {
        _subscribe(alice, PRINCIPAL / 2);
        _subscribe(bob, PRINCIPAL / 2);

        vm.prank(borrower);
        vault.drawdown();

        vm.prank(borrower);
        vm.expectRevert(LendingVault.AlreadyDrawnDown.selector);
        vault.drawdown();

        vm.prank(activator);
        vault.activate();

        _repay(5_000e6);

        // Past Drawdown there is no path back to the balance at all
        vm.prank(borrower);
        vm.expectRevert();
        vault.drawdown();

        assertEq(eurc.balanceOf(address(vault)), 5_000e6, "repayment stays put");
    }

    function test_drawdown_onlyBorrower() public {
        _subscribe(alice, PRINCIPAL);

        vm.prank(alice);
        vm.expectRevert(LendingVault.NotBorrower.selector);
        vault.drawdown();
    }

    /*//////////////////////////////////////////////////////////////
                            TERM & ACTIVATION
    //////////////////////////////////////////////////////////////*/

    /// R-29 / I-12: a build delay moves the start of the term, never its length.
    function test_term_lengthIsFixed_startFloats() public {
        _subscribe(alice, PRINCIPAL);

        vm.prank(borrower);
        vault.drawdown();

        vm.warp(block.timestamp + 60 days); // slow build

        vm.prank(activator);
        vault.activate();

        assertEq(vault.maturity(), block.timestamp + TERM, "full term still runs");
        assertEq(vault.maturity() - vault.activatedAt(), TERM);
    }

    function test_activate_onlyActivatorAndOnlyOnce() public {
        _subscribe(alice, PRINCIPAL);

        vm.prank(borrower);
        vault.drawdown();

        vm.prank(borrower);
        vm.expectRevert(LendingVault.NotActivator.selector);
        vault.activate();

        vm.prank(activator);
        vault.activate();

        vm.prank(activator);
        vm.expectRevert();
        vault.activate();
    }

    /// R-35: activating before drawdown would lock the borrower out of the principal they owe.
    function test_activate_requiresDrawdown() public {
        _subscribe(alice, PRINCIPAL);

        vm.prank(activator);
        vm.expectRevert(LendingVault.NotDrawnDown.selector);
        vault.activate();

        vm.prank(borrower);
        vault.drawdown();

        vm.prank(activator);
        vault.activate();

        assertEq(uint256(vault.phase()), uint256(LendingVault.Phase.Accruing));
    }

    /// R-28: never activating must not leave the vault inert forever with the money gone.
    function test_activationDeadline_missed_defaultsAndPaysOutWhatIsLeft() public {
        _subscribe(alice, PRINCIPAL);

        vm.warp(block.timestamp + ACTIVATION_WINDOW + 1);
        assertEq(uint256(vault.phase()), uint256(LendingVault.Phase.Default));

        // Borrower never drew down, so the subscription money is still here and belongs to lenders
        vault.finalize();
        assertEq(vault.settled(), PRINCIPAL, "undrawn principal recoverable");

        uint256 before = eurc.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(PRINCIPAL);
        assertEq(eurc.balanceOf(alice) - before, PRINCIPAL);
    }

    function test_activationDeadline_missedAfterDrawdown_lendersGetNothing() public {
        _subscribe(alice, PRINCIPAL);

        vm.prank(borrower);
        vault.drawdown();

        vm.warp(block.timestamp + ACTIVATION_WINDOW + 1);
        vault.finalize();

        assertTrue(vault.defaulted());
        assertEq(vault.settled(), 0, "money is gone; recourse is off-chain");
    }

    /*//////////////////////////////////////////////////////////////
                              REBASE RULES
    //////////////////////////////////////////////////////////////*/

    function test_rebase_onlyAdapter() public {
        _toAccruing();

        vm.warp(block.timestamp + 30 days);
        vm.prank(borrower);
        vm.expectRevert(LendingVault.NotAdapter.selector);
        vault.rebase(10e6, uint64(block.timestamp - 1 days));
    }

    /// R-25: a replayed period must not inflate the debt.
    function test_rebase_rejectsReplayedPeriod() public {
        _toAccruing();

        uint256 at = vault.activatedAt() + 30 days;
        vm.warp(at + 1 days);
        _rebase(50e6, at);

        vm.expectRevert(LendingVault.PeriodAlreadySeen.selector);
        vm.prank(adapter);
        vault.rebase(50e6, uint64(at));

        assertEq(vault.owed(), PRINCIPAL + 50e6, "counted once");
    }

    /// R-26: a mis-scaled oracle response cannot move the obligation arbitrarily.
    function test_rebase_boundsDelta() public {
        _toAccruing();

        uint256 at = vault.activatedAt() + 30 days;
        vm.warp(at + 1 days);

        vm.expectRevert(LendingVault.DeltaOutOfBounds.selector);
        vm.prank(adapter);
        vault.rebase(int256(MAX_DELTA + 1), uint64(at));

        vm.expectRevert(LendingVault.DeltaOutOfBounds.selector);
        vm.prank(adapter);
        vault.rebase(-int256(MAX_DELTA + 1), uint64(at));
    }

    /// R-26: the bound is relative to principal, and exactly the bound is accepted.
    function test_rebase_boundIsRelativeToPrincipal() public {
        _toAccruing();

        uint256 at = vault.activatedAt() + 30 days;
        vm.warp(at + 1 days);

        vm.prank(adapter);
        vault.rebase(int256(MAX_DELTA), uint64(at));

        assertEq(vault.owed(), PRINCIPAL + PRINCIPAL / 10);
    }

    function test_constructor_rejectsInvalidRebaseDeltaRatio() public {
        LendingVault.Config memory c = LendingVault.Config({
            borrower: borrower,
            activator: activator,
            claimToken: address(claim),
            tokenId: 2,
            collateralToken: address(eurc),
            principal: PRINCIPAL,
            fundingWindow: FUNDING_WINDOW,
            term: TERM,
            activationWindow: ACTIVATION_WINDOW,
            graceWindow: GRACE,
            maxRebaseDeltaRatio: 0,
            maxStaleness: MAX_STALENESS
        });

        vm.expectRevert(LendingVault.InvalidConfig.selector);
        new LendingVault(c, operator);

        c.maxRebaseDeltaRatio = 10_001;
        vm.expectRevert(LendingVault.InvalidConfig.selector);
        new LendingVault(c, operator);
    }

    function test_rebase_rejectsStaleUpdate() public {
        _toAccruing();

        uint256 at = vault.activatedAt() + 30 days;
        vm.warp(at + MAX_STALENESS + 1);

        vm.expectRevert(LendingVault.StaleUpdate.selector);
        vm.prank(adapter);
        vault.rebase(10e6, uint64(at));
    }

    /// R-23 / R-24 / I-4: `owed` is constant from maturity on. A fulfillment that arrives late is
    /// dropped, even for a period that ended before maturity — timeliness is an off-chain
    /// guarantee the contract cannot enforce, only refuse to act on once the window has closed.
    function test_rebase_accrualStopsDeadAtMaturity() public {
        _toAccruing();

        uint256 maturity = vault.maturity();
        uint64 lastPeriod = uint64(maturity - 1 days);

        vm.warp(maturity - 19 days);
        _rebase(25e6, maturity - 20 days);
        uint256 frozen = vault.owed();

        vm.warp(maturity);

        vm.expectRevert();
        vm.prank(adapter);
        vault.rebase(10e6, lastPeriod);

        vm.warp(maturity + 5 days);
        vm.expectRevert();
        vm.prank(adapter);
        vault.rebase(10e6, lastPeriod);

        assertEq(vault.owed(), frozen, "I-4: owed is constant after maturity");
    }

    function test_rebase_rejectsFutureDatedPeriod() public {
        _toAccruing();

        vm.warp(vault.activatedAt() + 30 days);

        vm.expectRevert(LendingVault.PeriodInFuture.selector);
        vm.prank(adapter);
        vault.rebase(10e6, uint64(block.timestamp + 1));
    }

    /// An early finalize (R-16, obligation already covered) freezes accrual too.
    function test_rebase_rejectedAfterEarlyFinalize() public {
        _toAccruing();

        uint256 period = vault.activatedAt() + 29 days;
        vm.warp(vault.activatedAt() + 30 days);
        _rebase(25e6, period);

        uint256 frozen = vault.owed();
        _repay(frozen);
        vault.finalize();

        assertLt(block.timestamp, vault.maturity(), "finalized before maturity");

        vm.expectRevert();
        vm.prank(adapter);
        vault.rebase(10e6, uint64(block.timestamp));

        assertEq(vault.owed(), frozen);
    }

    /// R-9: underperformance erodes premium, never principal.
    function test_owed_floorsAtPrincipal() public {
        _toAccruing();

        uint256 at = vault.activatedAt() + 30 days;
        vm.warp(at + 1 days);
        _rebase(20e6, at);
        assertEq(vault.owed(), PRINCIPAL + 20e6);

        at += 30 days;
        vm.warp(at + 1 days);
        _rebase(-100e6, at);

        assertEq(vault.owed(), PRINCIPAL, "I-3: principal is never forgiven");
    }

    /// R-10: a bad period offsets later profit rather than being forgiven.
    function test_negativePeriod_offsetsLaterProfit() public {
        _toAccruing();

        uint256 at = vault.activatedAt() + 30 days;
        vm.warp(at + 1 days);
        _rebase(-50e6, at);

        at += 30 days;
        vm.warp(at + 1 days);
        _rebase(80e6, at);

        // Net +30, not +80: the weak period was not clamped away
        assertEq(vault.owed(), PRINCIPAL + 30e6);
    }

    /*//////////////////////////////////////////////////////////////
                          NO EARLY REDEMPTION
    //////////////////////////////////////////////////////////////*/

    /// R-18 / §1.5: prepayment must not open an early exit.
    function test_noEarlyRedemption_evenWhenFullyPrepaid() public {
        _toAccruing();

        _repay(PRINCIPAL);

        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(1e6);

        // finalize() may run early once the obligation is covered (R-16), but not redeem before it
        vault.finalize();
        assertEq(vault.settled(), PRINCIPAL);
    }

    function test_claimTokensAreTransferable() public {
        _toAccruing();

        vm.prank(alice);
        claim.safeTransferFrom(alice, bob, TOKEN_ID, 1_000e6, "");

        assertEq(claim.balanceOf(bob, TOKEN_ID), PRINCIPAL / 2 + 1_000e6, "R-5");
    }

    /*//////////////////////////////////////////////////////////////
                           SURPLUS & ADMIN
    //////////////////////////////////////////////////////////////*/

    /// R-32: an overpaying borrower gets the excess back; lenders do not.
    function test_surplus_returnsToBorrower() public {
        _toAccruing();

        vm.warp(vault.maturity() + 1);
        uint256 owed = vault.owed();
        _repay(owed + 500e6);

        vault.finalize();
        assertEq(vault.settled(), owed);
        assertEq(vault.surplus(), 500e6);

        uint256 before = eurc.balanceOf(borrower);
        vm.prank(borrower);
        vault.withdrawSurplus();
        assertEq(eurc.balanceOf(borrower) - before, 500e6);
    }

    /// R-36: stray EURC is not repayment; the borrower gets it back only once every claim is gone.
    function test_remainder_strayEurcGoesToBorrowerAfterAllRedeemed() public {
        _toAccruing();

        vm.warp(vault.maturity() + 1);
        uint256 owed = vault.owed();
        _repay(owed);

        vm.prank(bob);
        eurc.transfer(address(vault), 123e6);

        vault.finalize();
        assertEq(vault.settled(), owed, "gift not counted as repayment");

        vm.prank(alice);
        vault.redeem(PRINCIPAL / 2);

        vm.prank(borrower);
        vm.expectRevert(LendingVault.ClaimsOutstanding.selector);
        vault.withdrawRemainder();

        vm.prank(bob);
        vault.redeem(PRINCIPAL / 2);

        vm.prank(alice);
        vm.expectRevert(LendingVault.NotBorrower.selector);
        vault.withdrawRemainder();

        uint256 before = eurc.balanceOf(borrower);
        vm.prank(borrower);
        vault.withdrawRemainder();

        assertEq(eurc.balanceOf(borrower) - before, 123e6);
        assertEq(eurc.balanceOf(address(vault)), 0);
    }

    function test_remainder_includesUnwithdrawnSurplus() public {
        _toAccruing();

        vm.warp(vault.maturity() + 1);
        _repay(vault.owed() + 500e6);
        vault.finalize();

        vm.prank(alice);
        vault.redeem(PRINCIPAL / 2);
        vm.prank(bob);
        vault.redeem(PRINCIPAL / 2);

        vm.prank(borrower);
        vault.withdrawRemainder();

        assertEq(vault.surplus(), 0);
        assertEq(eurc.balanceOf(address(vault)), 0);

        vm.prank(borrower);
        vm.expectRevert(LendingVault.ZeroAmount.selector);
        vault.withdrawSurplus();
    }

    function test_remainder_afterFailedRaiseOnceAllRefunded() public {
        _subscribe(alice, PRINCIPAL / 2);

        vm.prank(bob);
        eurc.transfer(address(vault), 7e6);

        vm.warp(vault.fundingDeadline());

        vm.prank(borrower);
        vm.expectRevert(LendingVault.ClaimsOutstanding.selector);
        vault.withdrawRemainder();

        vm.prank(alice);
        vault.refund(PRINCIPAL / 2);

        vm.prank(borrower);
        vault.withdrawRemainder();

        assertEq(eurc.balanceOf(address(vault)), 0);
    }

    function test_remainder_notBeforeTerminalPhase() public {
        _subscribe(alice, PRINCIPAL / 2);

        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(
                LendingVault.WrongPhase.selector, LendingVault.Phase.Redemption, LendingVault.Phase.Funding
            )
        );
        vault.withdrawRemainder();
    }

    /// R-19: the source of truth for the debt cannot change after lenders commit.
    function test_rebaseAdapter_frozenAfterFundingCloses() public {
        _subscribe(alice, PRINCIPAL);

        vm.prank(operator);
        vm.expectRevert(LendingVault.AdapterFrozen.selector);
        vault.setRebaseAdapter(address(0xBAD));
    }

    function test_operatorCannotMoveFunds() public {
        _subscribe(alice, PRINCIPAL);

        // §2.1: the operator has no money-moving surface, even in the phase that has one
        vm.prank(operator);
        vm.expectRevert(LendingVault.NotBorrower.selector);
        vault.drawdown();
    }

    /*//////////////////////////////////////////////////////////////
                              CLAIM TOKEN
    //////////////////////////////////////////////////////////////*/

    /// R-3: one collection serves many vaults; an id belongs to exactly one issuer, forever.
    function test_claimToken_issuerIsPerIdAndNotReassignable() public {
        vm.prank(operator);
        vm.expectRevert(SunToken.AlreadyIssued.selector);
        claim.setIssuer(TOKEN_ID, address(0xBAD), "x");

        vm.prank(address(0xBAD));
        vm.expectRevert(SunToken.NotIssuer.selector);
        claim.mint(alice, TOKEN_ID, 1e6);
    }

    function test_claimToken_secondVaultGetsItsOwnId() public {
        LendingVault.Config memory c = LendingVault.Config({
            borrower: borrower,
            activator: activator,
            claimToken: address(claim),
            tokenId: 2,
            collateralToken: address(eurc),
            principal: PRINCIPAL,
            fundingWindow: FUNDING_WINDOW,
            term: TERM,
            activationWindow: ACTIVATION_WINDOW,
            graceWindow: GRACE,
            maxRebaseDeltaRatio: MAX_REBASE_DELTA_RATIO,
            maxStaleness: MAX_STALENESS
        });
        LendingVault second = new LendingVault(c, operator);

        vm.prank(operator);
        claim.setIssuer(2, address(second), "vault-2.json");

        _subscribe(alice, PRINCIPAL);
        vm.startPrank(alice);
        eurc.approve(address(second), PRINCIPAL);
        second.subscribe(PRINCIPAL);
        vm.stopPrank();

        assertEq(claim.totalSupply(TOKEN_ID), PRINCIPAL);
        assertEq(claim.totalSupply(2), PRINCIPAL);
    }

    /*//////////////////////////////////////////////////////////////
                               FUZZING
    //////////////////////////////////////////////////////////////*/

    /// I-7 / I-13: payouts never exceed the settled pot, whatever the split or repayment.
    function testFuzz_payoutsNeverExceedSettled(uint256 split, uint256 repayment) public {
        split = bound(split, 1e6, PRINCIPAL - 1e6);
        repayment = bound(repayment, 0, PRINCIPAL);

        _subscribe(alice, split);
        _subscribe(bob, PRINCIPAL - split);

        vm.prank(borrower);
        vault.drawdown();
        vm.prank(activator);
        vault.activate();

        vm.warp(vault.maturity() + 1);
        if (repayment > 0) _repay(repayment);

        vm.warp(vault.maturity() + GRACE + 1);
        vault.finalize();

        uint256 paid;
        uint256 before = eurc.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(split);
        paid += eurc.balanceOf(alice) - before;

        before = eurc.balanceOf(bob);
        vm.prank(bob);
        vault.redeem(PRINCIPAL - split);
        paid += eurc.balanceOf(bob) - before;

        assertLe(paid, vault.settled(), "I-7");
        assertLe(paid, repayment, "never pays out more than came in");
    }
}
