// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/forge-std/src/Script.sol";
import { LendingVault } from "../src/LendingVault.sol";
import { SunToken } from "../src/SunToken.sol";

/**
 * Deploys one lending vault and binds it to its claim token id.
 *
 * The SunToken collection is deployed once and reused: set SUN_TOKEN_ADDRESS to an existing
 * collection to add a vault to it.
 *
 * Order matters — setIssuer must land before funding opens, or subscribe() cannot mint.
 */
contract DeployLendingVault is Script {
    function run() public {
        uint256 deployer = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address operator = vm.addr(deployer);

        address collateralToken = vm.envAddress("COLLATERAL_TOKEN_ADDRESS"); // EURC
        address borrower = vm.envAddress("BORROWER_ADDRESS");
        address activator = vm.envOr("ACTIVATOR_ADDRESS", operator);
        uint256 tokenId = vm.envUint("TOKEN_ID");
        uint256 principal = vm.envUint("PRINCIPAL");
        string memory tokenUri = vm.envString("TOKEN_URI");

        uint256 fundingWindow = vm.envOr("FUNDING_WINDOW", uint256(30 days));
        uint256 term = vm.envOr("TERM", uint256(5 * 365 days));
        uint256 activationWindow = vm.envOr("ACTIVATION_WINDOW", uint256(180 days));
        uint256 graceWindow = vm.envOr("GRACE_WINDOW", uint256(30 days));
        uint256 maxRebaseDeltaRatio = vm.envOr("MAX_REBASE_DELTA_RATIO", uint256(1_000)); // 10% of principal per rebase
        uint256 maxStaleness = vm.envOr("MAX_STALENESS", uint256(7 days));

        vm.startBroadcast(deployer);

        SunToken claimToken = SunToken(vm.envAddress("SUN_TOKEN_ADDRESS"));

        LendingVault vault = new LendingVault(
            LendingVault.Config({
                borrower: borrower,
                activator: activator,
                claimToken: address(claimToken),
                tokenId: tokenId,
                collateralToken: collateralToken,
                principal: principal,
                fundingWindow: fundingWindow,
                term: term,
                activationWindow: activationWindow,
                graceWindow: graceWindow,
                maxRebaseDeltaRatio: maxRebaseDeltaRatio,
                maxStaleness: maxStaleness
            }),
            operator
        );

        claimToken.setIssuer(tokenId, address(vault), tokenUri);

        // Adapter is settable only while funding is open (R-19)
        address adapter = vm.envOr("REBASE_ADAPTER_ADDRESS", address(0));
        if (adapter != address(0)) vault.setRebaseAdapter(adapter);

        vm.stopBroadcast();

        console.log("LendingVault:", address(vault));
        console.log("tokenId:", tokenId);
        console.log("principal:", principal);
        console.log("fundingDeadline:", vault.fundingDeadline());
    }
}
