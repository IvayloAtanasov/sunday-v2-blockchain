// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "lib/forge-std/src/Test.sol";
import { ERC20 } from "lib/solmate/src/tokens/ERC20.sol";
import { EnergyPriceOracle } from "../src/EnergyPriceOracle.sol";
import { LendingVault } from "../src/LendingVault.sol";
import { SunToken } from "../src/SunToken.sol";
import { YieldAdapter } from "../src/YieldAdapter.sol";

contract MockEURC is ERC20("Euro Coin", "EURC", 6) {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract YieldAdapterTest is Test {
    MockEURC eurc;
    SunToken claim;
    EnergyPriceOracle oracle;
    YieldAdapter adapter;
    LendingVault vaultA;
    LendingVault vaultB;

    address operator = address(0xA0);
    address publisher = address(0xB0);
    address borrower = address(0xC1);
    address activator = address(0xAC);
    address alice = address(0xA1);
    address stranger = address(0xBAD);

    bytes32 constant BG = bytes32("BG");

    string constant STATION_A = "SUN-0001";
    string constant STATION_B = "SUN-0002";

    uint256 constant PRINCIPAL = 10_000e6;
    uint256 constant FUNDING_WINDOW = 30 days;
    uint256 constant TERM = 365 days;
    uint256 constant ACTIVATION_WINDOW = 90 days;
    uint256 constant GRACE = 14 days;
    uint256 constant MAX_REBASE_DELTA_RATIO = 1_000; // 10% of principal
    uint256 constant MAX_STALENESS = 7 days;

    int128 constant MAX_ABS_PRICE = 2_000_000_000; // EUR 2000/MWh

    /// 60 kWh in a day, as milli-kWh. A plausible ceiling for a 10k installation.
    uint64 constant CAPACITY = 60_000;

    uint64 constant DAY = 86_400;

    /// 2023-11-15 00:00:00 in Sofia. A period start, and 900-aligned as every local midnight is.
    uint64 constant START = 1_699_999_200;

    function setUp() public {
        vm.warp(START);

        eurc = new MockEURC();

        vm.prank(operator);
        claim = new SunToken("ipfs://base");

        oracle = new EnergyPriceOracle(operator, publisher, MAX_ABS_PRICE);
        adapter = new YieldAdapter(operator, publisher, address(oracle));

        vaultA = _deployVault();
        vaultB = _deployVault();

        vm.startPrank(operator);
        adapter.registerVault(address(vaultA), STATION_A, BG, CAPACITY);
        adapter.registerVault(address(vaultB), STATION_B, BG, CAPACITY);
        vm.stopPrank();

        eurc.mint(alice, 1_000_000e6);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// Deploys a vault already bound to the adapter, as DeployLendingVault does.
    function _deployVault() internal returns (LendingVault vault) {
        LendingVault.Config memory c = LendingVault.Config({
            borrower: borrower,
            activator: activator,
            claimToken: address(claim),
            tokenId: 0, // replaced below
            collateralToken: address(eurc),
            principal: PRINCIPAL,
            fundingWindow: FUNDING_WINDOW,
            term: TERM,
            activationWindow: ACTIVATION_WINDOW,
            graceWindow: GRACE,
            maxRebaseDeltaRatio: MAX_REBASE_DELTA_RATIO,
            maxStaleness: MAX_STALENESS
        });

        c.tokenId = claim.nextTokenId();
        vault = new LendingVault(c, operator);

        vm.startPrank(operator);
        claim.createToken(address(vault));
        vault.setRebaseAdapter(address(adapter));
        vm.stopPrank();
    }

    function _toAccruing(LendingVault vault) internal {
        vm.startPrank(alice);
        eurc.approve(address(vault), PRINCIPAL);
        vault.subscribe(PRINCIPAL);
        vm.stopPrank();

        vm.prank(borrower);
        vault.drawdown();

        vm.prank(activator);
        vault.activate();
    }

    function _publishPrice(uint64 periodStart, int128 price) internal {
        vm.prank(publisher);
        oracle.publish(BG, periodStart, price);
    }

    function _one(address vault, uint64 periodStart, uint64 energyMilliKwh)
        internal
        pure
        returns (YieldAdapter.ProductionUpdate[] memory updates)
    {
        updates = new YieldAdapter.ProductionUpdate[](1);
        updates[0] = YieldAdapter.ProductionUpdate({
            vault: vault,
            periodStart: periodStart,
            energyMilliKwh: energyMilliKwh
        });
    }

    function _submit(YieldAdapter.ProductionUpdate[] memory updates) internal {
        vm.prank(publisher);
        adapter.submitProduction(updates);
    }

    /// The period after activation, with the clock moved far enough that it may be priced.
    function _settledPeriod(LendingVault vault) internal returns (uint64 periodStart) {
        periodStart = uint64(vault.activatedAt()) + DAY;
        vm.warp(uint256(periodStart) + DAY);
    }

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    function test_constructor_setsOwnerPublisherAndOracle() public view {
        assertEq(adapter.owner(), operator);
        assertEq(adapter.publisher(), publisher);
        assertEq(address(adapter.priceOracle()), address(oracle));
    }

    function test_constructor_rejectsZeroPriceOracle() public {
        vm.expectRevert(YieldAdapter.ZeroAddress.selector);
        new YieldAdapter(operator, publisher, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                              THE FORMULA
    //////////////////////////////////////////////////////////////*/

    /**
     * The formula this replaces ran as floating point inside a Chainlink Functions script, and
     * later as integers inside a CRE workflow. These five pairs are the fixtures both were held
     * against, with the expected values recomputed at the current EUR 1.25 fee. Each is within
     * two micro-EUR of what the original float formula produces for the same inputs, which is the
     * truncation difference and nothing else.
     *
     * Inputs are (kWh x 1e3, EUR/MWh x 1e6).
     */
    function test_netYield_matchesTheRetiredFormulaOnRepresentativeDays() public view {
        assertEq(adapter.netYield(1_200_000, 85_500_000), 71_977_500, "1200 kWh @ 85.5");
        assertEq(adapter.netYield(850_250, 120_000_000), 71_571_375, "850.25 kWh @ 120");
        assertEq(adapter.netYield(0, 95_000_000), -1_250_000, "0 kWh @ 95");
        assertEq(adapter.netYield(5_000_000, 42_125_000), 148_945_311, "5000 kWh @ 42.125");
        assertEq(adapter.netYield(73_400, 210_750_000), 9_896_697, "73.4 kWh @ 210.75");
    }

    /**
     * The fee moved from EUR 2.00 to EUR 1.25 when this replaced the CRE workflow. At the old fee
     * the first fixture yielded 71_302_500; the 0.75 EUR reduction survives the 10% corporate tax
     * as exactly 675_000 micro-EUR. Pinned so the rate change is asserted rather than assumed.
     */
    function test_netYield_feeReductionIsCarriedThroughTax() public view {
        assertEq(adapter.netYield(1_200_000, 85_500_000) - 71_302_500, 675_000);
        assertEq(adapter.PLATFORM_FEE_MICRO(), 1_250_000);
    }

    function test_netYield_zeroProductionStillChargesTheFee() public view {
        assertEq(adapter.netYield(0, 100_000_000), -1_250_000);
    }

    /// Tax applies to profit only, so a weak period is carried at its full negative value.
    function test_netYield_lossIsUntaxed() public view {
        int256 delta = adapter.netYield(1_000, 50_000_000);

        assertEq(delta, -1_210_417);
        assertLt(delta, -1_200_000, "no tax relief softened it");
    }

    function test_netYield_negativePriceCarriesThrough() public view {
        assertEq(adapter.netYield(1_200_000, -40_000_000), -39_250_000);
    }

    /*//////////////////////////////////////////////////////////////
                           WHO MAY SUBMIT
    //////////////////////////////////////////////////////////////*/

    function test_submitProduction_rejectsStranger() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(YieldAdapter.NotPublisher.selector, stranger));
        adapter.submitProduction(_one(address(vaultA), START, 30_000));
    }

    /// The operator key cannot move a claim. It configures; it does not report.
    function test_submitProduction_rejectsOwner() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(YieldAdapter.NotPublisher.selector, operator));
        adapter.submitProduction(_one(address(vaultA), START, 30_000));
    }

    /// An unconfigured adapter is inert, not open.
    function test_submitProduction_rejectsEverythingWhilePublisherUnset() public {
        YieldAdapter fresh = new YieldAdapter(operator, address(0), address(oracle));

        vm.prank(stranger);
        vm.expectRevert(YieldAdapter.PublisherNotSet.selector);
        fresh.submitProduction(_one(address(vaultA), START, 30_000));
    }

    function test_setPublisher_rotates() public {
        _toAccruing(vaultA);
        uint64 period = _settledPeriod(vaultA);
        _publishPrice(period, 100_000_000);

        address replacement = address(0xB1);
        vm.prank(operator);
        adapter.setPublisher(replacement);

        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(YieldAdapter.NotPublisher.selector, publisher));
        adapter.submitProduction(_one(address(vaultA), period, 30_000));

        vm.prank(replacement);
        adapter.submitProduction(_one(address(vaultA), period, 30_000));

        assertEq(vaultA.owed(), PRINCIPAL + 1_012_500);
    }

    function test_setPublisher_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert("UNAUTHORIZED");
        adapter.setPublisher(stranger);
    }

    /*//////////////////////////////////////////////////////////////
                            VAULT REGISTRY
    //////////////////////////////////////////////////////////////*/

    function test_registerVault_recordsBinding() public view {
        assertEq(adapter.vaultCount(), 2);
        assertEq(adapter.vaultAt(0), address(vaultA));
        assertEq(adapter.vaultAt(1), address(vaultB));
        assertTrue(adapter.isRegistered(address(vaultA)));
        assertEq(adapter.stationIdOf(address(vaultA)), STATION_A);
        assertEq(adapter.stationIdOf(address(vaultB)), STATION_B);
    }

    function test_registerVault_onlyOwner() public {
        LendingVault v = _deployVault();

        vm.prank(stranger);
        vm.expectRevert("UNAUTHORIZED");
        adapter.registerVault(address(v), STATION_A, BG, CAPACITY);
    }

    function test_registerVault_rejectsDuplicate() public {
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(YieldAdapter.AlreadyRegistered.selector, address(vaultA))
        );
        adapter.registerVault(address(vaultA), "SUN-9999", BG, CAPACITY);
    }

    function test_registerVault_rejectsEmptyStationId() public {
        LendingVault v = _deployVault();

        vm.prank(operator);
        vm.expectRevert(YieldAdapter.EmptyStationId.selector);
        adapter.registerVault(address(v), "", BG, CAPACITY);
    }

    function test_registerVault_rejectsEmptyCountry() public {
        LendingVault v = _deployVault();

        vm.prank(operator);
        vm.expectRevert(YieldAdapter.EmptyCountry.selector);
        adapter.registerVault(address(v), STATION_A, bytes32(0), CAPACITY);
    }

    /// A vault with no ceiling would have no bound on the one input nobody can verify.
    function test_registerVault_rejectsZeroCapacity() public {
        LendingVault v = _deployVault();

        vm.prank(operator);
        vm.expectRevert(YieldAdapter.InvalidCapacity.selector);
        adapter.registerVault(address(v), STATION_A, BG, 0);
    }

    /**
     * A vault that does not point back at this adapter could never be repaired: its adapter is
     * frozen once funding closes. Catching it at registration is the only chance.
     */
    function test_registerVault_rejectsVaultBoundToAnotherAdapter() public {
        LendingVault.Config memory c = LendingVault.Config({
            borrower: borrower,
            activator: activator,
            claimToken: address(claim),
            tokenId: claim.nextTokenId(),
            collateralToken: address(eurc),
            principal: PRINCIPAL,
            fundingWindow: FUNDING_WINDOW,
            term: TERM,
            activationWindow: ACTIVATION_WINDOW,
            graceWindow: GRACE,
            maxRebaseDeltaRatio: MAX_REBASE_DELTA_RATIO,
            maxStaleness: MAX_STALENESS
        });

        LendingVault orphan = new LendingVault(c, operator);

        vm.startPrank(operator);
        claim.createToken(address(orphan));
        orphan.setRebaseAdapter(address(0xDEAD));

        vm.expectRevert(
            abi.encodeWithSelector(
                YieldAdapter.AdapterMismatch.selector, address(orphan), address(0xDEAD)
            )
        );
        adapter.registerVault(address(orphan), STATION_A, BG, CAPACITY);
        vm.stopPrank();
    }

    /// Per vault: the bindings, and the watermark that decides which periods are still missing.
    function test_vaultState_reportsBindingsPhaseAndWatermark() public {
        _toAccruing(vaultA);
        uint64 period = _settledPeriod(vaultA);
        _publishPrice(period, 100_000_000);
        _submit(_one(address(vaultA), period, 30_000));

        YieldAdapter.VaultState memory a = adapter.vaultState(address(vaultA));

        assertTrue(a.registered);
        assertEq(a.stationId, STATION_A);
        assertEq(a.country, BG);
        assertEq(a.maxPeriodMilliKwh, CAPACITY);
        assertEq(a.phase, uint8(LendingVault.Phase.Accruing));
        assertEq(a.lastRebasedAt, period);

        // Untouched and still in Funding, so the publisher knows to skip it.
        YieldAdapter.VaultState memory b = adapter.vaultState(address(vaultB));

        assertTrue(b.registered);
        assertEq(b.phase, uint8(LendingVault.Phase.Funding));
        assertEq(b.lastRebasedAt, 0);
    }

    /**
     * The publisher asks for whatever its installation list held, so an address that was never
     * registered has to come back as a skippable answer rather than a revert that would cost
     * every other vault its run.
     */
    function test_vaultState_unknownVaultIsNotARevert() public view {
        YieldAdapter.VaultState memory state = adapter.vaultState(stranger);

        assertFalse(state.registered);
        assertEq(state.stationId, "");
        assertEq(state.country, bytes32(0));
        assertEq(state.maxPeriodMilliKwh, 0);
        assertEq(state.phase, 0);
        assertEq(state.lastRebasedAt, 0);
    }

    /*//////////////////////////////////////////////////////////////
                          PRODUCTION INTAKE
    //////////////////////////////////////////////////////////////*/

    /// The whole point: production and a published price go in, a premium comes out.
    function test_submitProduction_pricesProductionOnChain() public {
        _toAccruing(vaultA);
        uint64 period = _settledPeriod(vaultA);
        _publishPrice(period, 100_000_000);

        assertEq(adapter.netYield(30_000, 100_000_000), 1_012_500, "30 kWh @ 100 EUR/MWh");

        _submit(_one(address(vaultA), period, 30_000));

        assertEq(vaultA.owed(), PRINCIPAL + 1_012_500);
        assertEq(vaultA.lastRebasedAt(), period);
    }

    /// The log carries both inputs, so any past rebase can be recomputed from it.
    function test_submitProduction_emitsTheInputsItPricedFrom() public {
        _toAccruing(vaultA);
        uint64 period = _settledPeriod(vaultA);
        _publishPrice(period, 100_000_000);

        vm.expectEmit(true, false, false, true, address(adapter));
        emit YieldAdapter.Rebased(address(vaultA), 1_012_500, period, 30_000, 100_000_000);

        _submit(_one(address(vaultA), period, 30_000));
    }

    function test_submitProduction_appliesEveryItemInABatch() public {
        _toAccruing(vaultA);
        _toAccruing(vaultB);
        uint64 period = _settledPeriod(vaultA);
        _publishPrice(period, 100_000_000);

        YieldAdapter.ProductionUpdate[] memory updates = new YieldAdapter.ProductionUpdate[](2);
        updates[0] = YieldAdapter.ProductionUpdate(address(vaultA), period, 30_000);
        updates[1] = YieldAdapter.ProductionUpdate(address(vaultB), period, 1_000);

        _submit(updates);

        assertEq(vaultA.owed(), PRINCIPAL + 1_012_500);
        // A period earning less than the fee is negative, and principal is never cut by it.
        assertEq(vaultB.owed(), PRINCIPAL, "principal survives a weak period");
        assertLt(vaultB.cumulativeYield(), 0, "but the loss is remembered");
    }

    /**
     * The failure this design exists to prevent: one vault rejecting its update must not cost the
     * others their period. A rejection is that vault's own rules working.
     */
    function test_submitProduction_oneFailingVaultDoesNotBlockTheBatch() public {
        _toAccruing(vaultA);
        _toAccruing(vaultB);
        uint64 period = _settledPeriod(vaultA);
        _publishPrice(period, 100_000_000);

        // vaultA has already seen this period
        _submit(_one(address(vaultA), period, 30_000));

        YieldAdapter.ProductionUpdate[] memory updates = new YieldAdapter.ProductionUpdate[](2);
        updates[0] = YieldAdapter.ProductionUpdate(address(vaultA), period, 30_000);
        updates[1] = YieldAdapter.ProductionUpdate(address(vaultB), period, 30_000);

        vm.expectEmit(true, false, false, true, address(adapter));
        emit YieldAdapter.RebaseFailed(
            address(vaultA), period, abi.encodeWithSelector(LendingVault.PeriodAlreadySeen.selector)
        );

        _submit(updates);

        assertEq(vaultA.owed(), PRINCIPAL + 1_012_500, "not applied twice");
        assertEq(vaultB.owed(), PRINCIPAL + 1_012_500, "unaffected by its neighbour");
    }

    /// A vault still in Funding reverts with WrongPhase, which is recorded, not propagated.
    function test_submitProduction_recordsWrongPhaseWithoutReverting() public {
        _toAccruing(vaultA);
        uint64 period = _settledPeriod(vaultA);
        _publishPrice(period, 100_000_000);

        YieldAdapter.ProductionUpdate[] memory updates = new YieldAdapter.ProductionUpdate[](2);
        updates[0] = YieldAdapter.ProductionUpdate(address(vaultB), period, 30_000);
        updates[1] = YieldAdapter.ProductionUpdate(address(vaultA), period, 30_000);

        vm.expectEmit(true, false, false, true, address(adapter));
        emit YieldAdapter.RebaseFailed(
            address(vaultB),
            period,
            abi.encodeWithSelector(
                LendingVault.WrongPhase.selector,
                LendingVault.Phase.Accruing,
                LendingVault.Phase.Funding
            )
        );

        _submit(updates);

        assertEq(vaultA.owed(), PRINCIPAL + 1_012_500, "the healthy vault still accrued");
        assertEq(vaultB.owed(), PRINCIPAL);
    }

    /// The vault set comes from this contract, never from the submitted payload.
    function test_submitProduction_skipsUnregisteredVault() public {
        _toAccruing(vaultA);
        LendingVault rogue = _deployVault();
        _toAccruing(rogue);

        uint64 period = _settledPeriod(vaultA);
        _publishPrice(period, 100_000_000);

        YieldAdapter.ProductionUpdate[] memory updates = new YieldAdapter.ProductionUpdate[](2);
        updates[0] = YieldAdapter.ProductionUpdate(address(rogue), period, 50_000);
        updates[1] = YieldAdapter.ProductionUpdate(address(vaultA), period, 30_000);

        vm.expectEmit(true, false, false, true, address(adapter));
        emit YieldAdapter.UnregisteredVault(address(rogue), period);

        _submit(updates);

        assertEq(rogue.owed(), PRINCIPAL, "never touched");
        assertEq(vaultA.owed(), PRINCIPAL + 1_012_500);
    }

    /**
     * Normally a timing gap rather than a fault. The vault is left alone and the period stays
     * unreported, so the next run picks it up while the staleness window lasts.
     */
    function test_submitProduction_skipsAPeriodWithNoPublishedPrice() public {
        _toAccruing(vaultA);
        uint64 period = _settledPeriod(vaultA);

        vm.expectEmit(true, false, false, true, address(adapter));
        emit YieldAdapter.PriceMissing(address(vaultA), period);

        _submit(_one(address(vaultA), period, 30_000));

        assertEq(vaultA.owed(), PRINCIPAL);
        assertEq(vaultA.lastRebasedAt(), 0, "still unreported, so it can be retried");
    }

    /**
     * Production is the input nobody can verify independently, so a reading beyond what the
     * installation can physically produce is refused in the unit it is wrong in.
     */
    function test_submitProduction_rejectsProductionAboveCapacity() public {
        _toAccruing(vaultA);
        uint64 period = _settledPeriod(vaultA);
        _publishPrice(period, 100_000_000);

        vm.expectEmit(true, false, false, true, address(adapter));
        emit YieldAdapter.ProductionRejected(address(vaultA), period, CAPACITY + 1, CAPACITY);

        _submit(_one(address(vaultA), period, CAPACITY + 1));

        assertEq(vaultA.owed(), PRINCIPAL, "nothing accrued");

        // The ceiling itself is allowed.
        _submit(_one(address(vaultA), period, CAPACITY));
        assertGt(vaultA.owed(), PRINCIPAL);
    }

    function test_submitProduction_acceptsEmptyBatch() public {
        _submit(new YieldAdapter.ProductionUpdate[](0));

        assertEq(vaultA.owed(), PRINCIPAL);
    }

    /// An oversized delta is the vault's to refuse, and it costs only its own item.
    function test_submitProduction_outOfBoundsDeltaIsContained() public {
        _toAccruing(vaultA);
        _toAccruing(vaultB);

        // A vault whose ceiling is high enough to produce a delta past the vault's own bound.
        LendingVault big = _deployVault();
        vm.prank(operator);
        adapter.registerVault(address(big), "SUN-BIG", BG, 1_000_000);
        _toAccruing(big);

        uint64 period = _settledPeriod(vaultA);
        _publishPrice(period, MAX_ABS_PRICE);

        int256 bound = int256(PRINCIPAL * MAX_REBASE_DELTA_RATIO / 10_000);
        assertGt(
            adapter.netYield(1_000_000, MAX_ABS_PRICE), bound, "the fixture really is oversized"
        );

        YieldAdapter.ProductionUpdate[] memory updates = new YieldAdapter.ProductionUpdate[](2);
        updates[0] = YieldAdapter.ProductionUpdate(address(big), period, 1_000_000);
        updates[1] = YieldAdapter.ProductionUpdate(address(vaultA), period, 1_000);

        vm.expectEmit(true, false, false, true, address(adapter));
        emit YieldAdapter.RebaseFailed(
            address(big), period, abi.encodeWithSelector(LendingVault.DeltaOutOfBounds.selector)
        );

        _submit(updates);

        assertEq(big.owed(), PRINCIPAL);
        assertEq(vaultA.owed(), PRINCIPAL + 299_999, "its neighbour was still applied");
    }

    /// Accrual stops dead at maturity, and a late report is dropped rather than applied.
    function test_submitProduction_afterMaturityIsDropped() public {
        _toAccruing(vaultA);

        uint64 period = uint64(vaultA.maturity()) - DAY;
        vm.warp(vaultA.maturity() + 1);
        _publishPrice(period, 100_000_000);

        _submit(_one(address(vaultA), period, 30_000));

        assertEq(vaultA.owed(), PRINCIPAL);
    }

    /**
     * A malformed period key is not an ordinary rejection — it means whatever built the batch is
     * broken, which makes every other item in it suspect. That one reverts.
     */
    function test_submitProduction_revertsOnMisalignedPeriod() public {
        _toAccruing(vaultA);
        uint64 period = _settledPeriod(vaultA);
        _publishPrice(period, 100_000_000);

        uint64 notAMidnight = period + 137;

        vm.prank(publisher);
        vm.expectRevert(
            abi.encodeWithSelector(YieldAdapter.MisalignedPeriod.selector, notAMidnight)
        );
        adapter.submitProduction(_one(address(vaultA), notAMidnight, 30_000));
    }
}
