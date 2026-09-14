// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

/**
 * Surface the vault needs from the SunToken collection.
 *
 * Authorisation is per token id (R-3): the vault issues exactly one id and may mint and burn
 * only that id. Burning does not require the holder to have approved the vault (R-4).
 */
interface ISunToken {
    function mint(address to, uint256 id, uint256 amount) external;

    function burn(address from, uint256 id, uint256 amount) external;

    function totalSupply(uint256 id) external view returns (uint256);

    function balanceOf(address account, uint256 id) external view returns (uint256);
}
