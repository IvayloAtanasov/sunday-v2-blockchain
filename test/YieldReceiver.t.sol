// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "lib/forge-std/src/Test.sol";
import { ERC20 } from "lib/solmate/src/tokens/ERC20.sol";
import { LendingVault } from "../src/LendingVault.sol";
import { SunToken } from "../src/SunToken.sol";
import { YieldReceiver } from "../src/YieldReceiver.sol";
import { IReceiver } from "../src/interfaces/IReceiver.sol";

contract MockEURC is ERC20("Euro Coin", "EURC", 6) {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * The forwarder is mocked as a bare address: everything it does before calling `onReport` —
 * signature verification, DON config, report splitting — is Chainlink's code, and the only part
 * this receiver relies on is that the caller is that address and the metadata is laid out as
 * KeystoneForwarder slices it (`rawReport[45:109]`).
 */
contract YieldReceiverTest is Test {
    MockEURC eurc;
    SunToken claim;
    YieldReceiver receiver;
    LendingVault vaultA;
    LendingVault vaultB;

    address forwarder = address(0xF0);
    address operator = address(0xA0);
    address borrower = address(0xC1);
    address activator = address(0xAC);
    address alice = address(0xA1);
    address stranger = address(0xBAD);

    bytes32 constant WORKFLOW_ID = keccak256("sunday-pv-yield@1");
    bytes32 constant OTHER_WORKFLOW_ID = keccak256("someone-elses-workflow");

    string constant STATION_A = "SUN-0001";
    string constant STATION_B = "SUN-0002";

    uint256 constant PRINCIPAL = 10_000e6;
    uint256 constant FUNDING_WINDOW = 30 days;
    uint256 constant TERM = 365 days;
    uint256 constant ACTIVATION_WINDOW = 90 days;
    uint256 constant GRACE = 14 days;
    uint256 constant MAX_REBASE_DELTA_RATIO = 1_000; // 10% of principal
    uint256 constant MAX_STALENESS = 7 days;

    function setUp() public {
        vm.warp(1_700_000_000);

        eurc = new MockEURC();

        vm.prank(operator);
        claim = new SunToken("ipfs://base");

        receiver = new YieldReceiver(forwarder, operator);

        vaultA = _deployVault();
        vaultB = _deployVault();

        vm.startPrank(operator);
        receiver.registerVault(address(vaultA), STATION_A);
        receiver.registerVault(address(vaultB), STATION_B);
        receiver.setWorkflowId(WORKFLOW_ID);
        vm.stopPrank();

        eurc.mint(alice, 1_000_000e6);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// Deploys a vault already bound to the receiver, as DeployLendingVault does.
    function _deployVault() internal returns (LendingVault vault) {
        LendingVault.Config memory c = LendingVault.Config({
            borrower: borrower,
            activator: activator,
            claimToken: address(claim),
            tokenId: 0, // replaced below
            collateralToken: address(eurc),
            principal: PRINCIPAL,
            fundingWindow: FUNDING_WINDOW,
            term: TERM,
            activationWindow: ACTIVATION_WINDOW,
            graceWindow: GRACE,
            maxRebaseDeltaRatio: MAX_REBASE_DELTA_RATIO,
            maxStaleness: MAX_STALENESS
        });

        c.tokenId = claim.nextTokenId();
        vault = new LendingVault(c, operator);

        vm.startPrank(operator);
        claim.createToken(address(vault));
        vault.setRebaseAdapter(address(receiver));
        vm.stopPrank();
    }

    function _toAccruing(LendingVault vault) internal {
        vm.startPrank(alice);
        eurc.approve(address(vault), PRINCIPAL);
        vault.subscribe(PRINCIPAL);
        vm.stopPrank();

        vm.prank(borrower);
        vault.drawdown();

        vm.prank(activator);
        vault.activate();
    }

    /// The 64 bytes KeystoneForwarder hands to `onReport`.
    function _metadata(bytes32 id) internal pure returns (bytes memory) {
        return abi.encodePacked(id, bytes10("pv-yield"), address(0xDEAD), bytes2(0x0001));
    }

    function _one(address vault, int256 delta, uint256 at)
        internal
        pure
        returns (YieldReceiver.YieldUpdate[] memory updates)
    {
        updates = new YieldReceiver.YieldUpdate[](1);
        updates[0] = YieldReceiver.YieldUpdate({ vault: vault, delta: delta, updatedAt: uint64(at) });
    }

    function _deliver(YieldReceiver.YieldUpdate[] memory updates) internal {
        _deliverAs(WORKFLOW_ID, updates);
    }

    function _deliverAs(bytes32 id, YieldReceiver.YieldUpdate[] memory updates) internal {
        vm.prank(forwarder);
        receiver.onReport(_metadata(id), abi.encode(updates));
    }

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    function test_constructor_setsForwarderAndOwner() public view {
        assertEq(receiver.forwarder(), forwarder);
        assertEq(receiver.owner(), operator);
    }

    function test_constructor_rejectsZeroForwarder() public {
        vm.expectRevert(YieldReceiver.ZeroAddress.selector);
        new YieldReceiver(address(0), operator);
    }

    function test_supportsInterface() public view {
        assertTrue(receiver.supportsInterface(IReceiver.onReport.selector), "IReceiver");
        assertTrue(receiver.supportsInterface(0x01ffc9a7), "ERC165");
        assertFalse(receiver.supportsInterface(0xdeadbeef));
    }

    /*//////////////////////////////////////////////////////////////
                           WORKFLOW ID IS FROZEN
    //////////////////////////////////////////////////////////////*/

    function test_setWorkflowId_onlyOnce() public {
        assertEq(receiver.workflowId(), WORKFLOW_ID);

        vm.prank(operator);
        vm.expectRevert(YieldReceiver.WorkflowIdFrozen.selector);
        receiver.setWorkflowId(OTHER_WORKFLOW_ID);
    }

    function test_setWorkflowId_onlyOwner() public {
        YieldReceiver fresh = new YieldReceiver(forwarder, operator);

        vm.prank(stranger);
        vm.expectRevert("UNAUTHORIZED");
        fresh.setWorkflowId(WORKFLOW_ID);
    }

    function test_setWorkflowId_rejectsZero() public {
        YieldReceiver fresh = new YieldReceiver(forwarder, operator);

        vm.prank(operator);
        vm.expectRevert(YieldReceiver.WorkflowIdNotSet.selector);
        fresh.setWorkflowId(bytes32(0));
    }

    /// An unpinned receiver is inert, not open: it accepts nothing until the ID is set.
    function test_onReport_revertsBeforeWorkflowIdIsSet() public {
        YieldReceiver fresh = new YieldReceiver(forwarder, operator);

        vm.prank(forwarder);
        vm.expectRevert(YieldReceiver.WorkflowIdNotSet.selector);
        fresh.onReport(_metadata(WORKFLOW_ID), abi.encode(_one(address(vaultA), 1e6, block.timestamp)));
    }

    /*//////////////////////////////////////////////////////////////
                            VAULT REGISTRY
    //////////////////////////////////////////////////////////////*/

    function test_registerVault_recordsBinding() public view {
        assertEq(receiver.vaultCount(), 2);
        assertEq(receiver.vaultAt(0), address(vaultA));
        assertEq(receiver.vaultAt(1), address(vaultB));
        assertTrue(receiver.isRegistered(address(vaultA)));
        assertEq(receiver.stationIdOf(address(vaultA)), STATION_A);
        assertEq(receiver.stationIdOf(address(vaultB)), STATION_B);
    }

    function test_registerVault_onlyOwner() public {
        LendingVault v = _deployVault();

        vm.prank(stranger);
        vm.expectRevert("UNAUTHORIZED");
        receiver.registerVault(address(v), STATION_A);
    }

    function test_registerVault_rejectsDuplicate() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(YieldReceiver.AlreadyRegistered.selector, address(vaultA)));
        receiver.registerVault(address(vaultA), "SUN-9999");
    }

    function test_registerVault_rejectsEmptyStationId() public {
        LendingVault v = _deployVault();

        vm.prank(operator);
        vm.expectRevert(YieldReceiver.EmptyStationId.selector);
        receiver.registerVault(address(v), "");
    }

    /**
     * A vault that does not point back at this receiver could never be repaired: setRebaseAdapter
     * is frozen once funding closes (R-19). Catching it at registration is the only chance.
     */
    function test_registerVault_rejectsVaultBoundToAnotherAdapter() public {
        LendingVault.Config memory c = LendingVault.Config({
            borrower: borrower,
            activator: activator,
            claimToken: address(claim),
            tokenId: claim.nextTokenId(),
            collateralToken: address(eurc),
            principal: PRINCIPAL,
            fundingWindow: FUNDING_WINDOW,
            term: TERM,
            activationWindow: ACTIVATION_WINDOW,
            graceWindow: GRACE,
            maxRebaseDeltaRatio: MAX_REBASE_DELTA_RATIO,
            maxStaleness: MAX_STALENESS
        });

        LendingVault orphan = new LendingVault(c, operator);

        vm.startPrank(operator);
        claim.createToken(address(orphan));
        orphan.setRebaseAdapter(address(0xDEAD));

        vm.expectRevert(
            abi.encodeWithSelector(YieldReceiver.AdapterMismatch.selector, address(orphan), address(0xDEAD))
        );
        receiver.registerVault(address(orphan), STATION_A);
        vm.stopPrank();
    }

    /// Per vault: the station binding and the sync watermark the workflow prices against.
    function test_vaultState_reportsPhaseAndWatermark() public {
        _toAccruing(vaultA);

        uint256 at = vaultA.activatedAt() + 1 days;
        vm.warp(at + 1 hours);
        _deliver(_one(address(vaultA), 5e6, at));

        YieldReceiver.VaultState memory a = receiver.vaultState(address(vaultA));

        assertTrue(a.registered);
        assertEq(a.stationId, STATION_A);
        assertEq(a.phase, uint8(LendingVault.Phase.Accruing));
        assertEq(a.lastRebasedAt, uint64(at));

        // Untouched and still in Funding, so the workflow knows to skip it
        YieldReceiver.VaultState memory b = receiver.vaultState(address(vaultB));

        assertTrue(b.registered);
        assertEq(b.stationId, STATION_B);
        assertEq(b.phase, uint8(LendingVault.Phase.Funding));
        assertEq(b.lastRebasedAt, 0);
    }

    /**
     * The workflow asks for whatever the backend listed, so an address that was never registered
     * has to come back as a skippable answer. A revert here would cost every other vault its run.
     */
    function test_vaultState_unknownVaultIsNotARevert() public view {
        YieldReceiver.VaultState memory state = receiver.vaultState(stranger);

        assertFalse(state.registered);
        assertEq(state.stationId, "");
        assertEq(state.phase, 0);
        assertEq(state.lastRebasedAt, 0);
    }

    /*//////////////////////////////////////////////////////////////
                          REPORT AUTHORISATION
    //////////////////////////////////////////////////////////////*/

    function test_onReport_rejectsNonForwarder() public {
        _toAccruing(vaultA);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(YieldReceiver.NotForwarder.selector, stranger));
        receiver.onReport(_metadata(WORKFLOW_ID), abi.encode(_one(address(vaultA), 1e6, block.timestamp)));
    }

    /// The operator key cannot state a yield — the whole point of the migration.
    function test_onReport_rejectsOperator() public {
        _toAccruing(vaultA);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(YieldReceiver.NotForwarder.selector, operator));
        receiver.onReport(_metadata(WORKFLOW_ID), abi.encode(_one(address(vaultA), 1e6, block.timestamp)));
    }

    /// A correctly signed report from a different workflow is still a different formula.
    function test_onReport_rejectsForeignWorkflow() public {
        _toAccruing(vaultA);

        uint256 at = vaultA.activatedAt() + 1 days;
        vm.warp(at + 1 hours);

        vm.expectRevert(abi.encodeWithSelector(YieldReceiver.UnexpectedWorkflow.selector, OTHER_WORKFLOW_ID));
        _deliverAs(OTHER_WORKFLOW_ID, _one(address(vaultA), 1e6, at));

        assertEq(vaultA.owed(), PRINCIPAL, "nothing accrued");
    }

    function test_onReport_rejectsShortMetadata() public {
        vm.prank(forwarder);
        vm.expectRevert(YieldReceiver.InvalidMetadata.selector);
        receiver.onReport(abi.encodePacked(WORKFLOW_ID), abi.encode(_one(address(vaultA), 1e6, block.timestamp)));
    }

    /*//////////////////////////////////////////////////////////////
                              REPORT INTAKE
    //////////////////////////////////////////////////////////////*/

    function test_onReport_rebasesRegisteredVault() public {
        _toAccruing(vaultA);

        uint256 at = vaultA.activatedAt() + 1 days;
        vm.warp(at + 1 hours);

        vm.expectEmit(true, false, false, true, address(receiver));
        emit YieldReceiver.Rebased(address(vaultA), 42e6, uint64(at));

        _deliver(_one(address(vaultA), 42e6, at));

        assertEq(vaultA.owed(), PRINCIPAL + 42e6);
        assertEq(vaultA.lastRebasedAt(), uint64(at));
    }

    function test_onReport_appliesEveryItemInABatch() public {
        _toAccruing(vaultA);
        _toAccruing(vaultB);

        uint256 at = vaultA.activatedAt() + 1 days;
        vm.warp(at + 1 hours);

        YieldReceiver.YieldUpdate[] memory updates = new YieldReceiver.YieldUpdate[](2);
        updates[0] = YieldReceiver.YieldUpdate({ vault: address(vaultA), delta: 10e6, updatedAt: uint64(at) });
        updates[1] = YieldReceiver.YieldUpdate({ vault: address(vaultB), delta: -4e6, updatedAt: uint64(at) });

        _deliver(updates);

        assertEq(vaultA.owed(), PRINCIPAL + 10e6);
        assertEq(vaultB.owed(), PRINCIPAL, "R-9: negative period cannot cut principal");
        assertEq(vaultB.cumulativeYield(), -4e6, "R-10: but it is remembered");
    }

    /**
     * The failure this design exists to prevent: one vault rejecting its update must not cost the
     * others their day. A rejection is the vault's own rules working (R-24, R-25, R-26).
     */
    function test_onReport_oneFailingVaultDoesNotBlockTheBatch() public {
        _toAccruing(vaultA);
        _toAccruing(vaultB);

        uint256 at = vaultA.activatedAt() + 1 days;
        vm.warp(at + 1 hours);

        // vaultA has already seen this period
        _deliver(_one(address(vaultA), 10e6, at));

        YieldReceiver.YieldUpdate[] memory updates = new YieldReceiver.YieldUpdate[](2);
        updates[0] = YieldReceiver.YieldUpdate({ vault: address(vaultA), delta: 10e6, updatedAt: uint64(at) });
        updates[1] = YieldReceiver.YieldUpdate({ vault: address(vaultB), delta: 7e6, updatedAt: uint64(at) });

        vm.expectEmit(true, false, false, true, address(receiver));
        emit YieldReceiver.RebaseFailed(
            address(vaultA), uint64(at), abi.encodeWithSelector(LendingVault.PeriodAlreadySeen.selector)
        );

        _deliver(updates);

        assertEq(vaultA.owed(), PRINCIPAL + 10e6, "R-25: not applied twice");
        assertEq(vaultB.owed(), PRINCIPAL + 7e6, "unaffected by its neighbour");
    }

    /// A vault still in Funding reverts with WrongPhase and is recorded, not propagated.
    function test_onReport_recordsWrongPhaseWithoutReverting() public {
        _toAccruing(vaultA);

        uint256 at = vaultA.activatedAt() + 1 days;
        vm.warp(at + 1 hours);

        YieldReceiver.YieldUpdate[] memory updates = new YieldReceiver.YieldUpdate[](2);
        updates[0] = YieldReceiver.YieldUpdate({ vault: address(vaultB), delta: 3e6, updatedAt: uint64(at) });
        updates[1] = YieldReceiver.YieldUpdate({ vault: address(vaultA), delta: 3e6, updatedAt: uint64(at) });

        vm.expectEmit(true, false, false, true, address(receiver));
        emit YieldReceiver.RebaseFailed(
            address(vaultB),
            uint64(at),
            abi.encodeWithSelector(
                LendingVault.WrongPhase.selector, LendingVault.Phase.Accruing, LendingVault.Phase.Funding
            )
        );

        _deliver(updates);

        assertEq(vaultA.owed(), PRINCIPAL + 3e6, "the healthy vault still accrued");
        assertEq(vaultB.owed(), PRINCIPAL);
    }

    /// §8.6: the vault set comes from this contract, never from the report.
    function test_onReport_skipsUnregisteredVault() public {
        _toAccruing(vaultA);

        LendingVault rogue = _deployVault();
        _toAccruing(rogue);

        uint256 at = vaultA.activatedAt() + 1 days;
        vm.warp(at + 1 hours);

        YieldReceiver.YieldUpdate[] memory updates = new YieldReceiver.YieldUpdate[](2);
        updates[0] = YieldReceiver.YieldUpdate({ vault: address(rogue), delta: 500e6, updatedAt: uint64(at) });
        updates[1] = YieldReceiver.YieldUpdate({ vault: address(vaultA), delta: 1e6, updatedAt: uint64(at) });

        vm.expectEmit(true, false, false, true, address(receiver));
        emit YieldReceiver.UnregisteredVault(address(rogue), uint64(at));

        _deliver(updates);

        assertEq(rogue.owed(), PRINCIPAL, "never touched");
        assertEq(vaultA.owed(), PRINCIPAL + 1e6);
    }

    function test_onReport_acceptsEmptyBatch() public {
        YieldReceiver.YieldUpdate[] memory updates = new YieldReceiver.YieldUpdate[](0);

        _deliver(updates);

        assertEq(vaultA.owed(), PRINCIPAL);
    }

    /// R-26: an oversized delta is the vault's to refuse, and it costs only its own item.
    function test_onReport_outOfBoundsDeltaIsContained() public {
        _toAccruing(vaultA);
        _toAccruing(vaultB);

        uint256 at = vaultA.activatedAt() + 1 days;
        vm.warp(at + 1 hours);

        int256 tooBig = int256(PRINCIPAL * MAX_REBASE_DELTA_RATIO / 10_000) + 1;

        YieldReceiver.YieldUpdate[] memory updates = new YieldReceiver.YieldUpdate[](2);
        updates[0] = YieldReceiver.YieldUpdate({ vault: address(vaultA), delta: tooBig, updatedAt: uint64(at) });
        updates[1] = YieldReceiver.YieldUpdate({ vault: address(vaultB), delta: 1e6, updatedAt: uint64(at) });

        vm.expectEmit(true, false, false, true, address(receiver));
        emit YieldReceiver.RebaseFailed(
            address(vaultA), uint64(at), abi.encodeWithSelector(LendingVault.DeltaOutOfBounds.selector)
        );

        _deliver(updates);

        assertEq(vaultA.owed(), PRINCIPAL);
        assertEq(vaultB.owed(), PRINCIPAL + 1e6);
    }

    /// R-24: accrual stops dead at maturity, and a late report is dropped rather than applied.
    function test_onReport_afterMaturityIsDropped() public {
        _toAccruing(vaultA);

        uint256 at = vaultA.maturity() - 1 days;
        vm.warp(vaultA.maturity() + 1);

        _deliver(_one(address(vaultA), 9e6, at));

        assertEq(vaultA.owed(), PRINCIPAL, "R-24");
    }
}
