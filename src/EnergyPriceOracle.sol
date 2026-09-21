// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import { Owned } from "lib/solmate/src/auth/Owned.sol";
import { IEnergyPriceOracle } from "./interfaces/IEnergyPriceOracle.sol";

/**
 * Realized electricity prices, one per market per settlement period.
 *
 * Prices are **realized, not forecast**: they are collected for periods that have already ended,
 * so what is published here is what the market actually settled at. Nothing forward-looking is
 * ever written, and `publish` enforces that by refusing a period that has not finished.
 *
 * Global and shared. Every `YieldAdapter` reads from this same instance, so a formula change that
 * forces a new adapter does not force the price history to be republished, and anyone can check a
 * published day against the public record for that market.
 *
 * A price is written **once** and never revised. A realized price for a finished period is final,
 * and a vault rebased against that period cannot be un-rebased — the vault rejects a period it has
 * already seen. Allowing a revision would leave the chain disagreeing with itself: the premium
 * reflecting the old price and this contract the new one.
 *
 * What this contract is not: a defence against a stolen publisher key. `maxAbsPriceMicroPerMwh`
 * bounds a mis-parsed number, not a chosen one — see its declaration.
 */
contract EnergyPriceOracle is IEnergyPriceOracle, Owned {
    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// One market-period. Packs into a single slot.
    struct Price {
        int128 microPerMwh;
        bool published;
    }

    /*//////////////////////////////////////////////////////////////
                              PARAMETERS
    //////////////////////////////////////////////////////////////*/

    /**
     * Period keys are **period starts**, in local time, produced off-chain by the collectors and
     * used here verbatim. A daily price for 21 September 2026 is keyed at that day's local
     * midnight, not at its end and not at a UTC midnight. Every time series in this system —
     * prices and production alike — follows that convention, which is what lets a production
     * reading find its price by equality on a single number.
     *
     * This contract never decomposes a key into a date; it only checks that it plausibly is one.
     * Every modern UTC offset is a whole number of quarter-hours, so a local midnight in any zone
     * divides by 900, while an arbitrary instant almost never does. That is the whole check —
     * enough to catch a raw timestamp reaching this far, and agnostic about which zone produced
     * the key or whether it was in summer time at the time.
     */
    uint64 internal constant PERIOD_KEY_ALIGNMENT = 900;

    /**
     * Shortest a calendar day can be, in seconds: 23 hours, the length of a spring-forward day.
     *
     * Used only to establish that a daily period has certainly ended before its price may be
     * published. Being generous here costs nothing, because the collector targets a day that
     * finished long before the publisher runs.
     */
    uint64 internal constant MIN_PERIOD_LENGTH = 23 hours;

    /*//////////////////////////////////////////////////////////////
                            RUNNING STATE
    //////////////////////////////////////////////////////////////*/

    mapping(bytes32 country => mapping(uint64 periodStart => Price)) private _prices;

    /**
     * The only address that may publish. Zero means this contract accepts nothing, rather than
     * accepting anything — a deployed-but-unconfigured oracle is inert.
     *
     * Rotatable, unlike the formula in `YieldAdapter`. Freezing a formula protects lenders;
     * freezing a key would only mean that losing it permanently stops every vault accruing.
     */
    address public publisher;

    /**
     * Symmetric sanity bound on a published price, in EUR per MWh scaled by 1e6.
     *
     * A **parser guard, not a security cap.** The market gives no ceiling, so this number is
     * invented, and anyone holding the publisher key can simply publish just under it. What it
     * catches is the realistic failure: the price source changing its page layout so the scrape
     * picks up a volume cell or another market's row. A missing cell and an unpublished period
     * already throw off-chain; a plausible wrong number does not.
     *
     * Settable, for two reasons. An immutable ceiling on an unbounded quantity is a liveness
     * cliff — a genuine price above it could never be published, and once the vaults' staleness
     * window closed they would lose that period permanently. And it costs nothing in trust,
     * because the owner can already point `publisher` at itself; this never bounded the owner,
     * only a stolen key.
     */
    int128 public maxAbsPriceMicroPerMwh;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event PricePublished(bytes32 indexed country, uint64 indexed periodStart, int128 microPerMwh);
    event PublisherChanged(address oldPublisher, address newPublisher);
    event MaxAbsPriceChanged(int128 oldBound, int128 newBound);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotPublisher(address caller);
    error PublisherNotSet();
    error PriceAlreadyPublished(bytes32 country, uint64 periodStart);
    error PriceOutOfBounds(int128 microPerMwh, int128 bound);
    error MisalignedPeriod(uint64 periodStart);
    error PeriodNotEnded(uint64 periodStart);
    error LengthMismatch(uint256 periods, uint256 prices);
    error InvalidBound(int128 bound);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// `publisherAddress` may be zero; the oracle is then inert until `setPublisher`.
    constructor(address operator, address publisherAddress, int128 maxAbsPrice) Owned(operator) {
        if (maxAbsPrice <= 0) revert InvalidBound(maxAbsPrice);

        maxAbsPriceMicroPerMwh = maxAbsPrice;
        publisher = publisherAddress;

        emit MaxAbsPriceChanged(0, maxAbsPrice);
        emit PublisherChanged(address(0), publisherAddress);
    }

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyPublisher() {
        address current = publisher;

        if (current == address(0)) revert PublisherNotSet();
        if (msg.sender != current) revert NotPublisher(msg.sender);

        _;
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// Never reverts for an unknown period: the adapter calls this for whatever period it is handed.
    function priceOf(bytes32 country, uint64 periodStart)
        external
        view
        returns (int128 microPerMwh, bool published)
    {
        Price storage price = _prices[country][periodStart];

        return (price.microPerMwh, price.published);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMINISTRATION
    //////////////////////////////////////////////////////////////*/

    function setPublisher(address newPublisher) external onlyOwner {
        address old = publisher;
        publisher = newPublisher;

        emit PublisherChanged(old, newPublisher);
    }

    function setMaxAbsPrice(int128 newBound) external onlyOwner {
        if (newBound <= 0) revert InvalidBound(newBound);

        int128 old = maxAbsPriceMicroPerMwh;
        maxAbsPriceMicroPerMwh = newBound;

        emit MaxAbsPriceChanged(old, newBound);
    }

    /*//////////////////////////////////////////////////////////////
                              PUBLISHING
    //////////////////////////////////////////////////////////////*/

    function publish(bytes32 country, uint64 periodStart, int128 microPerMwh)
        external
        onlyPublisher
    {
        _publish(country, periodStart, microPerMwh);
    }

    /**
     * A backfill of several periods in one transaction.
     *
     * Atomic, unlike `YieldAdapter.submitProduction`. There a rejection is ordinary — a vault's
     * own period rules working as intended — so one item must not cost the others their day. Here
     * every rejection means the caller is wrong, nothing re-delivers this call, and the next
     * scheduled run retries the whole window anyway. Failing loudly is the more useful behaviour.
     */
    function publishMany(
        bytes32 country,
        uint64[] calldata periodStarts,
        int128[] calldata microPerMwh
    ) external onlyPublisher {
        if (periodStarts.length != microPerMwh.length) {
            revert LengthMismatch(periodStarts.length, microPerMwh.length);
        }

        for (uint256 i = 0; i < periodStarts.length; ++i) {
            _publish(country, periodStarts[i], microPerMwh[i]);
        }
    }

    function _publish(bytes32 country, uint64 periodStart, int128 microPerMwh) internal {
        if (periodStart == 0 || periodStart % PERIOD_KEY_ALIGNMENT != 0) {
            revert MisalignedPeriod(periodStart);
        }

        // A realized price only exists for a period that has finished.
        if (uint256(periodStart) + MIN_PERIOD_LENGTH > block.timestamp) {
            revert PeriodNotEnded(periodStart);
        }

        int128 bound = maxAbsPriceMicroPerMwh;
        if (microPerMwh > bound || microPerMwh < -bound) {
            revert PriceOutOfBounds(microPerMwh, bound);
        }

        if (_prices[country][periodStart].published) {
            revert PriceAlreadyPublished(country, periodStart);
        }

        _prices[country][periodStart] = Price({ microPerMwh: microPerMwh, published: true });

        emit PricePublished(country, periodStart, microPerMwh);
    }
}
