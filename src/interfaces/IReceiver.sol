// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

/**
 * Chainlink CRE report receiver.
 *
 * Declared locally rather than imported from lib/chainlink-evm: that copy pulls in OpenZeppelin
 * through a remapping this project does not carry, and the interface is four lines.
 *
 * The forwarder calls `onReport` after it has verified the DON signatures. A revert here is the
 * receiver's own rejection, not a consensus failure, and the forwarder records it as an
 * unsuccessful delivery rather than retrying automatically.
 */
interface IReceiver {
    function onReport(bytes calldata metadata, bytes calldata report) external;

    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
