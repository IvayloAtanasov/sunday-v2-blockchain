// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/forge-std/src/Script.sol";
import "../src/SunToken.sol";

contract DeploySunToken is Script {
    function setUp() public {}

    function run() public {
        uint256 deployer = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployer);

        string memory metadataBaseUri = "https://ipfs.io/ipfs";
        new SunToken(metadataBaseUri);

        vm.stopBroadcast();
    }
}
