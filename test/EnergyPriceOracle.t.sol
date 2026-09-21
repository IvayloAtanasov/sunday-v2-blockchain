// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "lib/forge-std/src/Test.sol";
import { EnergyPriceOracle } from "../src/EnergyPriceOracle.sol";

contract EnergyPriceOracleTest is Test {
    EnergyPriceOracle oracle;

    address operator = address(0xA0);
    address publisher = address(0xB0);
    address stranger = address(0xBAD);

    bytes32 constant BG = bytes32("BG");
    bytes32 constant RO = bytes32("RO");

    /// EUR 2000/MWh. Wide enough that no real settlement reaches it; narrow enough to catch a
    /// mis-parsed cell.
    int128 constant MAX_ABS_PRICE = 2_000_000_000;

    uint64 constant DAY = 86_400;

    /// 2023-11-15 00:00:00 in Sofia, which is winter time (UTC+2), so 22:00 UTC the day before.
    uint64 constant WINTER_PERIOD = 1_699_999_200;

    /// 2023-06-25 00:00:00 in Sofia, which is summer time (UTC+3), so 21:00 UTC the day before.
    uint64 constant SUMMER_PERIOD = 1_687_640_400;

    function setUp() public {
        // Well past both periods, so either may be published.
        vm.warp(uint256(WINTER_PERIOD) + 10 * DAY);

        oracle = new EnergyPriceOracle(operator, publisher, MAX_ABS_PRICE);
    }

    function _publish(uint64 periodStart, int128 price) internal {
        vm.prank(publisher);
        oracle.publish(BG, periodStart, price);
    }

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    function test_constructor_setsOwnerPublisherAndBound() public view {
        assertEq(oracle.owner(), operator);
        assertEq(oracle.publisher(), publisher);
        assertEq(oracle.maxAbsPriceMicroPerMwh(), MAX_ABS_PRICE);
    }

    function test_constructor_rejectsNonPositiveBound() public {
        vm.expectRevert(abi.encodeWithSelector(EnergyPriceOracle.InvalidBound.selector, int128(0)));
        new EnergyPriceOracle(operator, publisher, 0);

        vm.expectRevert(abi.encodeWithSelector(EnergyPriceOracle.InvalidBound.selector, int128(-1)));
        new EnergyPriceOracle(operator, publisher, -1);
    }

    /*//////////////////////////////////////////////////////////////
                           WHO MAY PUBLISH
    //////////////////////////////////////////////////////////////*/

    function test_publish_rejectsStranger() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(EnergyPriceOracle.NotPublisher.selector, stranger));
        oracle.publish(BG, WINTER_PERIOD, 100_000_000);
    }

    /// The owner configures the publisher; it is not one itself.
    function test_publish_rejectsOwner() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(EnergyPriceOracle.NotPublisher.selector, operator));
        oracle.publish(BG, WINTER_PERIOD, 100_000_000);
    }

    /// An unconfigured oracle is inert, not open.
    function test_publish_rejectsEverythingWhilePublisherUnset() public {
        EnergyPriceOracle fresh = new EnergyPriceOracle(operator, address(0), MAX_ABS_PRICE);

        vm.prank(stranger);
        vm.expectRevert(EnergyPriceOracle.PublisherNotSet.selector);
        fresh.publish(BG, WINTER_PERIOD, 100_000_000);
    }

    function test_setPublisher_rotates() public {
        address replacement = address(0xB1);

        vm.prank(operator);
        oracle.setPublisher(replacement);

        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(EnergyPriceOracle.NotPublisher.selector, publisher));
        oracle.publish(BG, WINTER_PERIOD, 100_000_000);

        vm.prank(replacement);
        oracle.publish(BG, WINTER_PERIOD, 100_000_000);

        (, bool published) = oracle.priceOf(BG, WINTER_PERIOD);
        assertTrue(published);
    }

    function test_setPublisher_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert("UNAUTHORIZED");
        oracle.setPublisher(stranger);
    }

    /*//////////////////////////////////////////////////////////////
                              PUBLISHING
    //////////////////////////////////////////////////////////////*/

    function test_publish_storesAndEmits() public {
        vm.expectEmit(true, true, false, true, address(oracle));
        emit EnergyPriceOracle.PricePublished(BG, WINTER_PERIOD, 153_310_000);

        _publish(WINTER_PERIOD, 153_310_000);

        (int128 price, bool published) = oracle.priceOf(BG, WINTER_PERIOD);
        assertEq(price, 153_310_000);
        assertTrue(published);
    }

    /// Markets are keyed separately: publishing one says nothing about another.
    function test_publish_isPerMarket() public {
        _publish(WINTER_PERIOD, 153_310_000);

        (, bool ro) = oracle.priceOf(RO, WINTER_PERIOD);
        assertFalse(ro);
    }

    /**
     * A realized price is final. Correcting one would leave the chain disagreeing with itself,
     * because any vault already rebased against it cannot be un-rebased.
     */
    function test_publish_isWriteOnce() public {
        _publish(WINTER_PERIOD, 153_310_000);

        vm.prank(publisher);
        vm.expectRevert(
            abi.encodeWithSelector(
                EnergyPriceOracle.PriceAlreadyPublished.selector, BG, WINTER_PERIOD
            )
        );
        oracle.publish(BG, WINTER_PERIOD, 999_000_000);

        (int128 price,) = oracle.priceOf(BG, WINTER_PERIOD);
        assertEq(price, 153_310_000, "the first publication stands");
    }

    /**
     * Zero is a price a market can settle at, so it must be distinguishable from "not published".
     * This is why `published` is a separate flag rather than a zero check.
     */
    function test_publish_zeroIsAPriceNotAnAbsence() public {
        (int128 before, bool publishedBefore) = oracle.priceOf(BG, WINTER_PERIOD);
        assertEq(before, 0);
        assertFalse(publishedBefore);

        _publish(WINTER_PERIOD, 0);

        (int128 price, bool published) = oracle.priceOf(BG, WINTER_PERIOD);
        assertEq(price, 0);
        assertTrue(published, "zero now means zero, not missing");
    }

    /// Negative settlements are ordinary in a market carrying a lot of renewable supply.
    function test_publish_acceptsNegativePrice() public {
        _publish(WINTER_PERIOD, -40_000_000);

        (int128 price, bool published) = oracle.priceOf(BG, WINTER_PERIOD);
        assertEq(price, -40_000_000);
        assertTrue(published);
    }

    function test_publish_boundsBothSigns() public {
        vm.prank(publisher);
        vm.expectRevert(
            abi.encodeWithSelector(
                EnergyPriceOracle.PriceOutOfBounds.selector, MAX_ABS_PRICE + 1, MAX_ABS_PRICE
            )
        );
        oracle.publish(BG, WINTER_PERIOD, MAX_ABS_PRICE + 1);

        vm.prank(publisher);
        vm.expectRevert(
            abi.encodeWithSelector(
                EnergyPriceOracle.PriceOutOfBounds.selector, -MAX_ABS_PRICE - 1, MAX_ABS_PRICE
            )
        );
        oracle.publish(BG, WINTER_PERIOD, -MAX_ABS_PRICE - 1);

        // The bound itself is allowed.
        _publish(WINTER_PERIOD, MAX_ABS_PRICE);
    }

    /*//////////////////////////////////////////////////////////////
                             PERIOD KEYS
    //////////////////////////////////////////////////////////////*/

    /// Local midnights in both summer and winter time are valid keys.
    function test_publish_acceptsLocalMidnightsAcrossDst() public {
        _publish(WINTER_PERIOD, 100_000_000);
        _publish(SUMMER_PERIOD, 90_000_000);

        (, bool winter) = oracle.priceOf(BG, WINTER_PERIOD);
        (, bool summer) = oracle.priceOf(BG, SUMMER_PERIOD);
        assertTrue(winter);
        assertTrue(summer);
    }

    function test_publish_rejectsMisalignedPeriod() public {
        uint64 notAMidnight = WINTER_PERIOD + 137;

        vm.prank(publisher);
        vm.expectRevert(
            abi.encodeWithSelector(EnergyPriceOracle.MisalignedPeriod.selector, notAMidnight)
        );
        oracle.publish(BG, notAMidnight, 100_000_000);
    }

    function test_publish_rejectsZeroPeriod() public {
        vm.prank(publisher);
        vm.expectRevert(
            abi.encodeWithSelector(EnergyPriceOracle.MisalignedPeriod.selector, uint64(0))
        );
        oracle.publish(BG, 0, 100_000_000);
    }

    /// A realized price only exists once the period it describes has finished.
    function test_publish_rejectsUnfinishedPeriod() public {
        uint64 today = uint64(block.timestamp) - (uint64(block.timestamp) % 900);

        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(EnergyPriceOracle.PeriodNotEnded.selector, today));
        oracle.publish(BG, today, 100_000_000);
    }

    /*//////////////////////////////////////////////////////////////
                              BACKFILLING
    //////////////////////////////////////////////////////////////*/

    function test_publishMany_storesEveryPeriod() public {
        uint64[] memory periods = new uint64[](3);
        int128[] memory prices = new int128[](3);

        for (uint256 i = 0; i < 3; ++i) {
            periods[i] = WINTER_PERIOD + uint64(i) * DAY;
            prices[i] = int128(int256(100_000_000 + i));
        }

        vm.prank(publisher);
        oracle.publishMany(BG, periods, prices);

        for (uint256 i = 0; i < 3; ++i) {
            (int128 price, bool published) = oracle.priceOf(BG, periods[i]);
            assertEq(price, prices[i]);
            assertTrue(published);
        }
    }

    function test_publishMany_rejectsLengthMismatch() public {
        uint64[] memory periods = new uint64[](2);
        int128[] memory prices = new int128[](1);

        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(EnergyPriceOracle.LengthMismatch.selector, 2, 1));
        oracle.publishMany(BG, periods, prices);
    }

    /**
     * Atomic, unlike the adapter's batch. A rejection here means the caller is wrong, nothing
     * re-delivers the call, and the next run retries the window — so failing whole is both safe
     * and the louder signal.
     */
    function test_publishMany_isAtomic() public {
        _publish(WINTER_PERIOD, 100_000_000);

        uint64[] memory periods = new uint64[](2);
        int128[] memory prices = new int128[](2);

        periods[0] = WINTER_PERIOD + DAY; // fine on its own
        prices[0] = 110_000_000;
        periods[1] = WINTER_PERIOD; // already published
        prices[1] = 120_000_000;

        vm.prank(publisher);
        vm.expectRevert(
            abi.encodeWithSelector(
                EnergyPriceOracle.PriceAlreadyPublished.selector, BG, WINTER_PERIOD
            )
        );
        oracle.publishMany(BG, periods, prices);

        (, bool published) = oracle.priceOf(BG, WINTER_PERIOD + DAY);
        assertFalse(published, "the good item rolled back with the bad one");
    }

    /*//////////////////////////////////////////////////////////////
                              THE BOUND
    //////////////////////////////////////////////////////////////*/

    /**
     * The bound is settable precisely so that a genuine price above it is not a permanent loss.
     * An immutable ceiling on an unbounded quantity would cost every vault that period once their
     * staleness window closed.
     */
    function test_setMaxAbsPrice_letsAPreviouslyRejectedPriceThrough() public {
        int128 spike = MAX_ABS_PRICE + 1;

        vm.prank(publisher);
        vm.expectRevert(
            abi.encodeWithSelector(
                EnergyPriceOracle.PriceOutOfBounds.selector, spike, MAX_ABS_PRICE
            )
        );
        oracle.publish(BG, WINTER_PERIOD, spike);

        vm.expectEmit(false, false, false, true, address(oracle));
        emit EnergyPriceOracle.MaxAbsPriceChanged(MAX_ABS_PRICE, spike);

        vm.prank(operator);
        oracle.setMaxAbsPrice(spike);

        _publish(WINTER_PERIOD, spike);

        (int128 price,) = oracle.priceOf(BG, WINTER_PERIOD);
        assertEq(price, spike);
    }

    function test_setMaxAbsPrice_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert("UNAUTHORIZED");
        oracle.setMaxAbsPrice(1);
    }

    function test_setMaxAbsPrice_rejectsNonPositive() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(EnergyPriceOracle.InvalidBound.selector, int128(0)));
        oracle.setMaxAbsPrice(0);
    }
}
