// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import { Owned } from "lib/solmate/src/auth/Owned.sol";
import { IEnergyPriceOracle } from "./interfaces/IEnergyPriceOracle.sol";
import { ILendingVault } from "./interfaces/ILendingVault.sol";

/**
 * Turns a measured production reading into a vault's premium, and pushes it into `rebase()`.
 *
 * The premium is computed **here**, on-chain, from two inputs: how much the installation produced
 * over a settlement period, and what the market settled at for that period. Neither the operator
 * nor the publisher key can state a yield — they can only assert those two inputs, and both are
 * bounded. A lender can read the arithmetic that moves their claim in `netYield` below, and can
 * recompute any past rebase from the inputs carried in the `Rebased` event.
 *
 * That is the whole design. An adapter that accepted a finished number would be trusting whoever
 * held the key to have computed it honestly, which is what the earlier Chainlink Functions
 * version did and what this replaces.
 *
 * Three things are frozen, deliberately and with no escape hatch:
 *
 *   - the formula, as constants in this contract;
 *   - the price oracle it reads, at construction;
 *   - each vault's station, market and capacity binding, at `registerVault`.
 *
 * The publisher key is **not** among them: it is rotatable. Freezing a formula protects lenders,
 * because it is what they were sold. Freezing a key protects nobody — it only means that losing
 * one permanently stops every vault bound to this adapter from accruing.
 *
 * The cost of the freeze is that correcting a rate needs a new adapter and therefore new vaults,
 * since a vault's adapter is fixed once its funding closes. Existing vaults keep the formula they
 * were sold with for the length of their term. Accrued premium and principal are never at risk;
 * the worst case is that accrual stops and what is owed stays where it is.
 */
contract YieldAdapter is Owned {
    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// One vault-period of measured production, as submitted by the publisher.
    struct ProductionUpdate {
        address vault;
        uint64 periodStart;
        uint64 energyMilliKwh;
    }

    /// A vault's permanent bindings, set once at registration.
    struct Registration {
        bytes32 country;
        uint64 maxPeriodMilliKwh;
        bool registered;
        string stationId;
    }

    /// What the publisher needs about one vault to decide which periods are missing.
    struct VaultState {
        bool registered;
        string stationId;
        bytes32 country;
        uint64 maxPeriodMilliKwh;
        uint8 phase;
        uint64 lastRebasedAt;
    }

    /*//////////////////////////////////////////////////////////////
                              THE FORMULA
    //////////////////////////////////////////////////////////////*/

    /**
     * Every rate is public so that a lender can read the exact arithmetic applied to their claim,
     * rather than being asked to trust that some off-chain code implements what it says it does.
     *
     * All values are in EURC minor units, which at six decimals is also micro-EUR.
     */

    /// The electricity trader's cut off the market price, by contract. 5%.
    int256 public constant BUYER_DISCOUNT_NUM = 95;
    int256 public constant BUYER_DISCOUNT_DEN = 100;

    /// VAT, stripped back out of the gross revenue. 20%.
    int256 public constant VAT_NUM = 100;
    int256 public constant VAT_DEN = 120;

    /**
     * Flat platform fee, in micro-EUR. EUR 1.25.
     *
     * Charged **per rebase, not per unit of time**. At the daily reporting cadence these are the
     * same thing; at any other cadence the effective fee would move with it. Being flat, it is
     * regressive in installation size: immaterial on a large installation, and most of the margin
     * on a small one, where it is what can push a weak period negative.
     */
    int256 public constant PLATFORM_FEE_MICRO = 1_250_000;

    /// Corporate tax, applied to profit only. 10%.
    int256 public constant CORPORATE_TAX_NUM = 90;
    int256 public constant CORPORATE_TAX_DEN = 100;

    /*//////////////////////////////////////////////////////////////
                              PARAMETERS
    //////////////////////////////////////////////////////////////*/

    /**
     * Period keys are period starts in local time, produced off-chain and used verbatim, so that
     * a production reading and a price meet by equality on a single number. This contract never
     * decomposes one into a date; it only checks that it plausibly is one, since every modern UTC
     * offset is a whole number of quarter-hours.
     */
    uint64 internal constant PERIOD_KEY_ALIGNMENT = 900;

    /**
     * Where prices come from. Immutable: a settable price source is a settable source of truth
     * for what a vault owes, which is exactly what a vault freezes on its own side when its
     * funding closes.
     */
    IEnergyPriceOracle public immutable priceOracle;

    /*//////////////////////////////////////////////////////////////
                            RUNNING STATE
    //////////////////////////////////////////////////////////////*/

    mapping(address vault => Registration) private _registrations;

    address[] private _vaults;

    /**
     * The only address that may submit production. Zero means this adapter accepts nothing rather
     * than accepting anything, so one deployed but not yet configured is inert.
     */
    address public publisher;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event PublisherChanged(address oldPublisher, address newPublisher);
    event VaultRegistered(
        address indexed vault, string stationId, bytes32 country, uint64 maxPeriodMilliKwh
    );

    /// Carries the inputs as well as the result, so any rebase can be recomputed from its log.
    event Rebased(
        address indexed vault,
        int256 delta,
        uint64 periodStart,
        uint64 energyMilliKwh,
        int128 priceMicroPerMwh
    );
    event RebaseFailed(address indexed vault, uint64 periodStart, bytes reason);
    event UnregisteredVault(address indexed vault, uint64 periodStart);
    event PriceMissing(address indexed vault, uint64 periodStart);
    event ProductionRejected(
        address indexed vault, uint64 periodStart, uint64 energyMilliKwh, uint64 capacity
    );

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotPublisher(address caller);
    error PublisherNotSet();
    error ZeroAddress();
    error AlreadyRegistered(address vault);
    error EmptyStationId();
    error EmptyCountry();
    error InvalidCapacity();
    error AdapterMismatch(address vault, address adapter);
    error MisalignedPeriod(uint64 periodStart);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// `publisherAddress` may be zero; the adapter is then inert until `setPublisher`.
    constructor(address operator, address publisherAddress, address priceOracleAddress)
        Owned(operator)
    {
        if (priceOracleAddress == address(0)) revert ZeroAddress();

        priceOracle = IEnergyPriceOracle(priceOracleAddress);
        publisher = publisherAddress;

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
                              THE FORMULA
    //////////////////////////////////////////////////////////////*/

    /**
     * What one vault-period of production is worth, in EURC minor units.
     *
     * Public and pure so that it can be called against any inputs, from a block explorer or a
     * test, without a vault being involved.
     *
     * Integer-only throughout. Division truncates toward zero, which is why the tax is guarded
     * rather than applied unconditionally: a loss-making period is carried at its full negative
     * value, because tax relief on a bad period is not something this instrument grants.
     */
    function netYield(uint64 energyMilliKwh, int256 priceMicroPerMwh)
        public
        pure
        returns (int256)
    {
        // The price is per MWh and the energy is in kWh, so the factor of 1/1000 between them is
        // folded into the scale below:
        //   (priceMicro / 1e6 / 1000) EUR/kWh  x  (energyMilli / 1e3) kWh  x  1e6 micro/EUR
        // = priceMicro * energyMilli / 1e6
        int256 marketValue = (priceMicroPerMwh * int256(uint256(energyMilliKwh))) / 1e6;

        int256 revenue = (marketValue * BUYER_DISCOUNT_NUM) / BUYER_DISCOUNT_DEN;
        int256 taxable = (revenue * VAT_NUM) / VAT_DEN - PLATFORM_FEE_MICRO;

        return taxable > 0 ? (taxable * CORPORATE_TAX_NUM) / CORPORATE_TAX_DEN : taxable;
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function vaultCount() external view returns (uint256) {
        return _vaults.length;
    }

    function vaultAt(uint256 index) external view returns (address) {
        return _vaults[index];
    }

    function isRegistered(address vault) external view returns (bool) {
        return _registrations[vault].registered;
    }

    function stationIdOf(address vault) external view returns (string memory) {
        return _registrations[vault].stationId;
    }

    /**
     * One vault's bindings, phase and last reported period.
     *
     * The publisher enumerates installations from its own records — the same list the indexer and
     * the app use, so a missing installation fails visibly everywhere rather than only here — and
     * then asks this for each one. That list says which vaults exist; this says what each one is.
     * A wrong row there can cost a vault its period, but cannot misprice one: the bindings are
     * read here, and `submitProduction` rejects anything unregistered.
     *
     * `lastRebasedAt` is the watermark that decides which periods are still missing. It lives on
     * the vault, not in any database, so a period that failed on-chain can never look done.
     *
     * Never reverts for an unknown address. It is called with whatever the publisher listed, and
     * a revert here would cost every other vault its run, so an unregistered vault comes back
     * with `registered == false` and is skipped by the caller.
     */
    function vaultState(address vault) external view returns (VaultState memory state) {
        Registration storage registration = _registrations[vault];

        if (!registration.registered) {
            return state;
        }

        state = VaultState({
            registered: true,
            stationId: registration.stationId,
            country: registration.country,
            maxPeriodMilliKwh: registration.maxPeriodMilliKwh,
            phase: ILendingVault(vault).phase(),
            lastRebasedAt: ILendingVault(vault).lastRebasedAt()
        });
    }

    /*//////////////////////////////////////////////////////////////
                            ADMINISTRATION
    //////////////////////////////////////////////////////////////*/

    function setPublisher(address newPublisher) external onlyOwner {
        address old = publisher;
        publisher = newPublisher;

        emit PublisherChanged(old, newPublisher);
    }

    /**
     * Bind a vault to the installation whose production backs it. Once per vault, never revised.
     *
     * The target vault is decided here, on-chain, and never taken from a submitted payload — the
     * same reason the price is looked up from the registered market rather than being submitted
     * alongside the reading.
     *
     * `maxPeriodMilliKwh` is a physical ceiling on what the installation can produce in one
     * period. Production is the one input nobody can verify independently, since it comes from
     * the inverter, so this is what bounds a wrong or malicious reading in the unit it is wrong
     * in. It cannot be revised, because a settable ceiling would not be a bound on the operator.
     *
     * The vault must already point back at this adapter. A vault's adapter freezes when its
     * funding closes, so one registered without that binding could never be fixed and would fail
     * every rebase forever.
     */
    function registerVault(
        address vault,
        string calldata stationId,
        bytes32 country,
        uint64 maxPeriodMilliKwh
    ) external onlyOwner {
        if (vault == address(0)) revert ZeroAddress();
        if (_registrations[vault].registered) revert AlreadyRegistered(vault);
        if (bytes(stationId).length == 0) revert EmptyStationId();
        if (country == bytes32(0)) revert EmptyCountry();
        if (maxPeriodMilliKwh == 0) revert InvalidCapacity();

        address adapter = ILendingVault(vault).rebaseAdapter();
        if (adapter != address(this)) revert AdapterMismatch(vault, adapter);

        _registrations[vault] = Registration({
            country: country,
            maxPeriodMilliKwh: maxPeriodMilliKwh,
            registered: true,
            stationId: stationId
        });
        _vaults.push(vault);

        emit VaultRegistered(vault, stationId, country, maxPeriodMilliKwh);
    }

    /*//////////////////////////////////////////////////////////////
                           PRODUCTION INTAKE
    //////////////////////////////////////////////////////////////*/

    /**
     * Price a batch of measured production readings and apply each one to its vault.
     *
     * Two kinds of failure, treated differently on purpose.
     *
     * A reading that a vault or this adapter declines is **ordinary**: the period was already
     * seen, the term has ended, the delta is out of bounds, the price for that period has not
     * been published yet. Those are the rules working as intended, and they must not become a
     * reason for a whole batch to be lost, so each is emitted and the loop continues. Letting the
     * batch revert would also throw away every other vault's period for the sake of one.
     *
     * A malformed period key is **not** ordinary — it means whatever built this batch is broken,
     * which makes every other item in it suspect too. That reverts.
     */
    function submitProduction(ProductionUpdate[] calldata updates) external onlyPublisher {
        for (uint256 i = 0; i < updates.length; ++i) {
            ProductionUpdate calldata update = updates[i];

            if (update.periodStart == 0 || update.periodStart % PERIOD_KEY_ALIGNMENT != 0) {
                revert MisalignedPeriod(update.periodStart);
            }

            Registration storage registration = _registrations[update.vault];

            // The publisher reads its vault list from this contract, so this cannot happen
            // without the publisher being wrong. Skipped rather than reverted, for the reason
            // the per-item handling exists at all.
            if (!registration.registered) {
                emit UnregisteredVault(update.vault, update.periodStart);
                continue;
            }

            if (update.energyMilliKwh > registration.maxPeriodMilliKwh) {
                emit ProductionRejected(
                    update.vault,
                    update.periodStart,
                    update.energyMilliKwh,
                    registration.maxPeriodMilliKwh
                );
                continue;
            }

            (int128 priceMicroPerMwh, bool published) =
                priceOracle.priceOf(registration.country, update.periodStart);

            // Normally a timing gap rather than a fault: the price for this period has not been
            // published yet. The next run picks it up, while the vault's staleness window lasts.
            if (!published) {
                emit PriceMissing(update.vault, update.periodStart);
                continue;
            }

            int256 delta = netYield(update.energyMilliKwh, priceMicroPerMwh);

            try ILendingVault(update.vault).rebase(delta, update.periodStart) {
                emit Rebased(
                    update.vault, delta, update.periodStart, update.energyMilliKwh, priceMicroPerMwh
                );
            } catch (bytes memory reason) {
                emit RebaseFailed(update.vault, update.periodStart, reason);
            }
        }
    }
}
