// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import { Owned } from "lib/solmate/src/auth/Owned.sol";
import { IReceiver } from "./interfaces/IReceiver.sol";
import { ILendingVault } from "./interfaces/ILendingVault.sol";

/**
 * Chainlink CRE report receiver. Pushes measured profit into the vaults' `rebase()`.
 *
 * Replaces ChainlinkYieldAdapter, which accepted arbitrary JavaScript from the operator key and
 * took the target vault out of the oracle response. Here the formula is pinned as a workflow ID
 * and the vault set is on-chain, so the operator can add a vault but cannot state a yield.
 *
 * Three things are frozen, and deliberately have no escape hatch:
 *
 *   - the forwarder, at construction;
 *   - the workflow ID, at the single `setWorkflowId` call that follows deployment;
 *   - each vault's station binding, at `registerVault`.
 *
 * The cost is that a new formula, or a Chainlink forwarder migration, needs a new receiver and
 * therefore new vaults. That is the intended trade: a lender reading this contract can see which
 * computation may move their claim, and that nobody — including the operator — can change it for
 * the life of their vault. Accrued premium and principal are never at risk from the freeze; the
 * worst case is that accrual stops and `owed` stays where it is.
 *
 * Implements docs/lending-vault-spec.md §8. Requirement tags (R-n) refer to that document.
 */
contract YieldReceiver is IReceiver, Owned {
    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// One vault-day of measured profit, as carried in a report
    struct YieldUpdate {
        address vault;
        int256 delta;
        uint64 updatedAt;
    }

    /// What the workflow needs about one vault to decide which days are missing
    struct VaultState {
        bool registered;
        string stationId;
        uint8 phase;
        uint64 lastRebasedAt;
    }

    struct Registration {
        string stationId;
        bool registered;
    }

    /*//////////////////////////////////////////////////////////////
                              PARAMETERS
    //////////////////////////////////////////////////////////////*/

    /// Metadata is `workflowId(32) | workflowName(10) | workflowOwner(20) | reportId(2)`
    uint256 internal constant MIN_METADATA_LENGTH = 62;

    /**
     * KeystoneForwarder for this chain. Immutable: a settable forwarder is a settable source of
     * truth, which is exactly what R-19 freezes on the vault side.
     */
    address public immutable forwarder;

    /*//////////////////////////////////////////////////////////////
                            RUNNING STATE
    //////////////////////////////////////////////////////////////*/

    /**
     * Hash of the workflow binary and its config. Zero until set, and set exactly once.
     *
     * It cannot be a constructor argument: the workflow config names this receiver, and the ID is
     * a hash over that config, so the two would have to know each other's address first.
     */
    bytes32 public workflowId;

    mapping(address vault => Registration) private _registrations;

    address[] private _vaults;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event WorkflowIdSet(bytes32 workflowId);
    event VaultRegistered(address indexed vault, string stationId);
    event Rebased(address indexed vault, int256 delta, uint64 updatedAt);
    event RebaseFailed(address indexed vault, uint64 updatedAt, bytes reason);
    event UnregisteredVault(address indexed vault, uint64 updatedAt);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotForwarder(address caller);
    error WorkflowIdNotSet();
    error WorkflowIdFrozen();
    error UnexpectedWorkflow(bytes32 workflowId);
    error InvalidMetadata();
    error ZeroAddress();
    error AlreadyRegistered(address vault);
    error EmptyStationId();
    error AdapterMismatch(address vault, address adapter);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address forwarderAddress, address operator) Owned(operator) {
        if (forwarderAddress == address(0)) revert ZeroAddress();

        forwarder = forwarderAddress;
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function vaultCount() external view returns (uint256) {
        return _vaults.length;
    }

    function vaultAt(uint256 index) external view returns (address) {
        return _vaults[index];
    }

    function isRegistered(address vault) external view returns (bool) {
        return _registrations[vault].registered;
    }

    function stationIdOf(address vault) external view returns (string memory) {
        return _registrations[vault].stationId;
    }

    /**
     * One vault's station binding, phase and last reported period.
     *
     * The workflow enumerates installations from the backend — the same list the indexer and the
     * app use, so a missing installation fails visibly everywhere rather than only here — and then
     * asks this for each one. Mongo says which vaults exist; this says what each one is. A wrong
     * row there can cost a vault its day, but cannot misprice one: the station binding is read
     * here, and `onReport` rejects anything unregistered.
     *
     * Never reverts for an unknown address. It is called with whatever the backend listed, and a
     * revert inside a chain read would cost every other vault its run, so an unregistered vault
     * comes back with `registered == false` and is skipped by the caller.
     */
    function vaultState(address vault) external view returns (VaultState memory state) {
        Registration storage registration = _registrations[vault];

        if (!registration.registered) {
            return state;
        }

        state = VaultState({
            registered: true,
            stationId: registration.stationId,
            phase: ILendingVault(vault).phase(),
            lastRebasedAt: ILendingVault(vault).lastRebasedAt()
        });
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        // IReceiver.onReport, and ERC165 itself
        return interfaceId == IReceiver.onReport.selector || interfaceId == 0x01ffc9a7;
    }

    /*//////////////////////////////////////////////////////////////
                            ADMINISTRATION
    //////////////////////////////////////////////////////////////*/

    /**
     * Pin the workflow whose reports this receiver accepts. Once, and never again.
     *
     * Deploy the workflow first, read its ID, then call this. Until it is called the receiver
     * accepts nothing, so a receiver deployed but not yet pinned is inert rather than open.
     */
    function setWorkflowId(bytes32 id) external onlyOwner {
        if (workflowId != bytes32(0)) revert WorkflowIdFrozen();
        if (id == bytes32(0)) revert WorkflowIdNotSet();

        workflowId = id;

        emit WorkflowIdSet(id);
    }

    /**
     * Bind a vault to the PV station whose production backs it. Once per vault, never revised.
     *
     * This is the check §8.6 asks for: the target vault is decided here, on-chain, and not taken
     * from the oracle response. Adding a vault changes no workflow config and therefore does not
     * move the workflow ID — which is the reason the vault list lives in the contract rather than
     * in the workflow.
     *
     * The vault must already point back at this receiver. `setRebaseAdapter` is frozen once
     * funding closes (R-19), so a vault registered without that binding could never be fixed, and
     * would report `RebaseFailed` forever.
     */
    function registerVault(address vault, string calldata stationId) external onlyOwner {
        if (vault == address(0)) revert ZeroAddress();
        if (_registrations[vault].registered) revert AlreadyRegistered(vault);
        if (bytes(stationId).length == 0) revert EmptyStationId();

        address adapter = ILendingVault(vault).rebaseAdapter();
        if (adapter != address(this)) revert AdapterMismatch(vault, adapter);

        _registrations[vault] = Registration({ stationId: stationId, registered: true });
        _vaults.push(vault);

        emit VaultRegistered(vault, stationId);
    }

    /*//////////////////////////////////////////////////////////////
                              REPORT INTAKE
    //////////////////////////////////////////////////////////////*/

    /**
     * Apply a batch of measured yields.
     *
     * Each `rebase` is wrapped, so one vault that rejects its update cannot strand the rest of the
     * batch. A vault rejecting an update is ordinary: the period was already seen (R-25), the term
     * has ended (R-24), or the delta is out of bounds (R-26). Those are the vault's rules working,
     * and they must not become a reason for a whole day's reports to be lost.
     *
     * Letting the batch fail instead would also make the report a candidate for re-delivery, and
     * a report delivered twice is the one thing the vault's period rules are there to stop.
     */
    function onReport(bytes calldata metadata, bytes calldata report) external {
        if (msg.sender != forwarder) revert NotForwarder(msg.sender);
        if (metadata.length < MIN_METADATA_LENGTH) revert InvalidMetadata();

        bytes32 expected = workflowId;
        if (expected == bytes32(0)) revert WorkflowIdNotSet();

        bytes32 reported = bytes32(metadata[0:32]);
        if (reported != expected) revert UnexpectedWorkflow(reported);

        YieldUpdate[] memory updates = abi.decode(report, (YieldUpdate[]));

        for (uint256 i = 0; i < updates.length; ++i) {
            YieldUpdate memory u = updates[i];

            // The workflow reads its vault list from this contract, so this cannot happen
            // without the workflow being wrong. Skipped rather than reverted, for the reason
            // the per-item wrapping exists.
            if (!_registrations[u.vault].registered) {
                emit UnregisteredVault(u.vault, u.updatedAt);
                continue;
            }

            try ILendingVault(u.vault).rebase(u.delta, u.updatedAt) {
                emit Rebased(u.vault, u.delta, u.updatedAt);
            } catch (bytes memory reason) {
                emit RebaseFailed(u.vault, u.updatedAt, reason);
            }
        }
    }
}
