// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/forge-std/src/Script.sol";
import { YieldReceiver } from "../src/YieldReceiver.sol";

/**
 * Deploys the CRE report receiver.
 *
 * The workflow ID is deliberately not set here. The workflow's config names this receiver, and the
 * ID hashes that config, so the address has to exist first. Deploy this, put the address in the
 * workflow config, deploy the workflow, then run SetWorkflowId with the ID it reports.
 *
 * Until that second step the receiver accepts no reports at all.
 *
 * CRE_FORWARDER_ADDRESS is the KeystoneForwarder for the target chain, from Chainlink's forwarder
 * directory. Arc testnet is 0x76c9cf548b4179F8901cda1f8623568b58215E62, and its simulation
 * forwarder — for `cre workflow simulate --broadcast` — is 0x6E9EE680ef59ef64Aa8C7371279c27E496b5eDc1.
 * It is immutable once deployed, so a receiver pointed at the simulation forwarder is a testing
 * receiver for good.
 */
contract DeployYieldReceiver is Script {
    function run() public {
        uint256 deployer = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address operator = vm.addr(deployer);

        address forwarder = vm.envAddress("CRE_FORWARDER_ADDRESS");

        vm.startBroadcast(deployer);

        YieldReceiver receiver = new YieldReceiver(forwarder, operator);

        vm.stopBroadcast();

        console.log("YieldReceiver:", address(receiver));
    }
}
