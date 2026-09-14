// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/forge-std/src/Script.sol";
import { ChainlinkYieldAdapter } from "../src/ChainlinkYieldAdapter.sol";
import { LendingVault } from "../src/LendingVault.sol";

contract DeployChainlinkYieldAdapter is Script {
    function run() public {
        uint256 deployer = vm.envUint("DEPLOYER_PRIVATE_KEY");

        address routerAddress = vm.envAddress("FUNCTIONS_ROUTER");
        address vaultAddress = vm.envOr("LENDING_VAULT", address(0));

        vm.startBroadcast(deployer);

        ChainlinkYieldAdapter adapter = new ChainlinkYieldAdapter(routerAddress);

        // Only possible while the vault's funding window is still open (R-19)
        if (vaultAddress != address(0)) {
            LendingVault(vaultAddress).setRebaseAdapter(address(adapter));
        }

        vm.stopBroadcast();

        console.log("ChainlinkYieldAdapter:", address(adapter));
    }
}
