// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

interface IEnergyPriceOracle {
    /**
     * The realized price for a market and a settlement period, in EUR per MWh scaled by 1e6.
     *
     * `periodStart` is the **start** of the period, not its end — the convention every time
     * series in this system uses. The price for 21 September 2026 is keyed at that day's local
     * midnight.
     *
     * `published` is returned separately rather than encoded as a zero price: a market can and
     * does settle at exactly zero, so zero is an answer, not an absence.
     */
    function priceOf(bytes32 country, uint64 periodStart)
        external
        view
        returns (int128 microPerMwh, bool published);
}
