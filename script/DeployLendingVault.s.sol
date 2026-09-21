// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/forge-std/src/Script.sol";
import { LendingVault } from "../src/LendingVault.sol";
import { SunToken } from "../src/SunToken.sol";
import { YieldAdapter } from "../src/YieldAdapter.sol";

/**
 * Deploys one lending vault and binds it to its claim token id.
 *
 * The SunToken collection is deployed once and reused: set SUN_TOKEN_ADDRESS to an existing
 * collection to add a vault to it.
 *
 * The token id is assigned by SunToken, not configured: the script reads nextTokenId() and builds
 * the vault for it, then createToken() binds that same id. Deploy vaults one at a time from one
 * operator, or the id can be taken in between.
 *
 * Order matters — createToken must land before funding opens, or subscribe() cannot mint.
 *
 * One YieldAdapter serves every vault, so YIELD_ADAPTER_ADDRESS is set once per network and this
 * script is re-run per vault with a new BORROWER_ADDRESS, STATION_ID, PRINCIPAL, TOKEN_URI and
 * MAX_PERIOD_MILLI_KWH.
 *
 * None of the adapter, the station, the market or the capacity ceiling is optional. The vault binds
 * to the adapter before funding opens and can never be rebound, and the bindings on the adapter are
 * equally final — so a vault deployed against the wrong one, or against none, has to be abandoned
 * rather than corrected.
 *
 * MAX_PERIOD_MILLI_KWH is the most the installation can physically produce in one reporting period,
 * in kWh x 1e3. It is what bounds a wrong production reading, so it should be the installation's
 * real ceiling with a little headroom, not a round number chosen for convenience.
 */
contract DeployLendingVault is Script {
    function run() public {
        uint256 deployer = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address operator = vm.addr(deployer);

        address adapter = vm.envAddress("YIELD_ADAPTER_ADDRESS");
        string memory stationId = vm.envString("STATION_ID");
        bytes32 country = bytes32(bytes(vm.envOr("STATION_COUNTRY", string("BG"))));
        uint64 maxPeriodMilliKwh = uint64(vm.envUint("MAX_PERIOD_MILLI_KWH"));

        SunToken claimToken = SunToken(vm.envAddress("SUN_TOKEN_ADDRESS"));
        uint256 tokenId = claimToken.nextTokenId();
        LendingVault.Config memory config = _config(operator, address(claimToken), tokenId);

        vm.startBroadcast(deployer);

        LendingVault vault = new LendingVault(config, operator);

        require(
            claimToken.createToken(address(vault)) == tokenId, "token id taken during deployment"
        );
        claimToken.setURI(tokenId, vm.envString("TOKEN_URI"));

        // The adapter is settable only while funding is open, and it refuses to register a vault
        // that is not already pointing at it — so this order is the only one that works.
        vault.setRebaseAdapter(adapter);
        YieldAdapter(adapter).registerVault(address(vault), stationId, country, maxPeriodMilliKwh);

        vm.stopBroadcast();

        console.log("LendingVault:", address(vault));
        console.log("tokenId:", tokenId);
        console.log("principal:", config.principal);
        console.log("fundingDeadline:", vault.fundingDeadline());
        console.log("station:", stationId);
        console.log("maxPeriodMilliKwh:", maxPeriodMilliKwh);
        console.log("adapter:", adapter);
    }

    /// Kept out of run(), which holds more locals than the stack allows once the config is inlined
    function _config(address operator, address claimToken, uint256 tokenId)
        internal
        view
        returns (LendingVault.Config memory)
    {
        return LendingVault.Config({
            borrower: vm.envAddress("BORROWER_ADDRESS"),
            activator: vm.envOr("ACTIVATOR_ADDRESS", operator),
            claimToken: claimToken,
            tokenId: tokenId,
            collateralToken: vm.envAddress("COLLATERAL_TOKEN_ADDRESS"), // EURC
            principal: vm.envUint("PRINCIPAL"),
            fundingWindow: vm.envOr("FUNDING_WINDOW", uint256(30 days)),
            term: vm.envOr("TERM", uint256(5 * 365 days)),
            activationWindow: vm.envOr("ACTIVATION_WINDOW", uint256(180 days)),
            graceWindow: vm.envOr("GRACE_WINDOW", uint256(30 days)),
            maxRebaseDeltaRatio: vm.envOr("MAX_REBASE_DELTA_RATIO", uint256(1_000)), // 10% of principal
            maxStaleness: vm.envOr("MAX_STALENESS", uint256(7 days))
        });
    }
}
