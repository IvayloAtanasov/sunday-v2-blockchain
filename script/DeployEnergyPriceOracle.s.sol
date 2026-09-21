// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/forge-std/src/Script.sol";
import { EnergyPriceOracle } from "../src/EnergyPriceOracle.sol";

/**
 * Deploys the shared price oracle. One per network, deployed first.
 *
 * Every YieldAdapter reads from this instance and pins its address at construction, so replacing
 * the oracle means replacing every adapter and therefore every vault. Deploy it once and keep it.
 *
 * PRICE_PUBLISHER_ADDRESS may be left empty: the oracle then accepts nothing until setPublisher is
 * called, which is the safe state to deploy into if the publisher key does not exist yet.
 *
 * MAX_ABS_PRICE_MICRO_PER_MWH is a sanity bound on a published price, in EUR/MWh x 1e6, applied to
 * both signs. It catches a mis-parsed number, not a chosen one — anyone holding the publisher key
 * can publish just under it. Set it well above any price the market realistically settles at; it
 * is adjustable later, so erring wide costs nothing and erring narrow stops accrual.
 */
contract DeployEnergyPriceOracle is Script {
    function run() public {
        uint256 deployer = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address operator = vm.addr(deployer);

        address publisher = vm.envOr("PRICE_PUBLISHER_ADDRESS", address(0));
        // Default EUR 2000/MWh.
        int128 maxAbsPrice =
            int128(int256(vm.envOr("MAX_ABS_PRICE_MICRO_PER_MWH", uint256(2_000_000_000))));

        vm.startBroadcast(deployer);

        EnergyPriceOracle oracle = new EnergyPriceOracle(operator, publisher, maxAbsPrice);

        vm.stopBroadcast();

        console.log("EnergyPriceOracle:", address(oracle));
        console.log("operator:", operator);
        console.log("publisher:", publisher);
        console.log("maxAbsPriceMicroPerMwh:", vm.toString(maxAbsPrice));

        if (publisher == address(0)) {
            console.log("NOTE: no publisher set, the oracle accepts nothing until setPublisher");
        }
    }
}
