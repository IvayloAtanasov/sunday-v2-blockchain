// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/forge-std/src/Script.sol";
import { YieldAdapter } from "../src/YieldAdapter.sol";

/**
 * Deploys the adapter that prices production and rebases vaults. Deployed after the price oracle,
 * before any vault.
 *
 * The formula lives in this contract as constants, and the price oracle address is fixed at
 * construction. Correcting either means a new adapter, and a vault's adapter is frozen once its
 * funding closes — so a new adapter serves only new vaults, and the vaults on this one keep the
 * formula they were sold with for the length of their term. Read YieldAdapter before deploying it.
 *
 * YIELD_PUBLISHER_ADDRESS may be left empty: the adapter then accepts nothing until setPublisher is
 * called, which is the safe state to deploy into if the publisher key does not exist yet. Unlike
 * the formula, the publisher is rotatable — losing a key must not permanently stop accrual.
 */
contract DeployYieldAdapter is Script {
    function run() public {
        uint256 deployer = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address operator = vm.addr(deployer);

        address priceOracle = vm.envAddress("PRICE_ORACLE_ADDRESS");
        address publisher = vm.envOr("YIELD_PUBLISHER_ADDRESS", address(0));

        vm.startBroadcast(deployer);

        YieldAdapter adapter = new YieldAdapter(operator, publisher, priceOracle);

        vm.stopBroadcast();

        console.log("YieldAdapter:", address(adapter));
        console.log("operator:", operator);
        console.log("publisher:", publisher);
        console.log("priceOracle:", priceOracle);
        console.log("platformFeeMicro:", uint256(adapter.PLATFORM_FEE_MICRO()));

        if (publisher == address(0)) {
            console.log("NOTE: no publisher set, the adapter accepts nothing until setPublisher");
        }
    }
}
