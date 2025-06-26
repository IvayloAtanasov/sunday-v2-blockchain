// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/forge-std/src/Script.sol";
import "../src/FundingVault.sol";
import "../src/SunToken.sol";

contract DeployFundingVault is Script {
    function setUp() public {}

    function run() public {
        uint256 deployer = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployer);

        uint256 assetTokenId = 1;
        string memory tokenMetadataUri = "bafkreiebrb44gvbrxfvcsyjus2m27wyx5f225k6o6hxnjktdjxqqdcsjde";

        // create vault
        address assetTokenAddress = 0xCA65a75b7475e32C6C4563D95328E75cEc6fB038; // SUN
        address borrowerAddress = 0xe64c80DaC84aeE6983C3a2945a84f757e98c6B40; // Deployer
        address collateralTokenAddress = 0x5E44db7996c682E92a960b65AC713a54AD815c6B; // EURC
        uint256 funding = 1_000_000; // 1 EURC
        uint256 term = 604_800; // 7 days

        FundingVault vault = new FundingVault(
            borrowerAddress,
            assetTokenAddress,
            assetTokenId,
            collateralTokenAddress,
            funding,
            term
        );

        // mint 1155 asset token on vault
        bytes memory tokenData = "";
        SunToken assetToken = SunToken(assetTokenAddress);
        assetToken.mint(
            address(vault),
            assetTokenId,
            funding,
            tokenData,
            tokenMetadataUri
        );

        vm.stopBroadcast();
    }
}
