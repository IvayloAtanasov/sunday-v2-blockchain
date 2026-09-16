// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/forge-std/src/Script.sol";
import { YieldReceiver } from "../src/YieldReceiver.sol";

/**
 * Pins the workflow a receiver will accept reports from. Runs exactly once per receiver, and
 * cannot be undone or repeated — a different formula means a new receiver and new vaults.
 *
 * WORKFLOW_ID is the ID the CRE CLI reports for the deployed workflow.
 */
contract SetWorkflowId is Script {
    function run() public {
        uint256 deployer = vm.envUint("DEPLOYER_PRIVATE_KEY");

        YieldReceiver receiver = YieldReceiver(vm.envAddress("YIELD_RECEIVER_ADDRESS"));
        bytes32 workflowId = vm.envBytes32("WORKFLOW_ID");

        require(receiver.workflowId() == bytes32(0), "workflow id already frozen");

        vm.startBroadcast(deployer);

        receiver.setWorkflowId(workflowId);

        vm.stopBroadcast();
    }
}
