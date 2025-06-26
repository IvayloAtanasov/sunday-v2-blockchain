// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/forge-std/src/Script.sol";
import "../src/ChainlinkYieldAdapter.sol";
import "../src/FundingVault.sol";

contract DeployChainlinkYieldAdapter is Script {
    function setUp() public {}

    function run() public {
        uint256 deployer = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployer);

        address fundingVaultAddress = 0xB31b14C2fDF48fdc4AC2dd0a6B7c37f972F96349; // Sun #1 funding vault

        // create adapter
        address routerAddress = 0xA9d587a00A31A52Ed70D6026794a8FC5E2F5dCb0; // Avalanche Fuji Chainlink router
        ChainlinkYieldAdapter adapter = new ChainlinkYieldAdapter(routerAddress);

        // allow adapter to update funding vault yield
        FundingVault fundingVault = FundingVault(fundingVaultAddress);
        fundingVault.setRebaseAdapter(address(adapter));

        vm.stopBroadcast();
    }
}
