// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { ERC1155 } from "lib/solmate/src/tokens/ERC1155.sol";
import { OwnerIsCreator } from "lib/chainlink/contracts/src/v0.8/shared/access/OwnerIsCreator.sol";

/**
 * Shared ERC1155 collection. One token id per lending vault.
 *
 * Authorisation is per id, not per collection (R-3). Ids are assigned sequentially: each
 * createToken() binds the next id to its issuing vault, and from then on only that vault may mint
 * and burn it. An id is never bound twice — claims lenders already hold must not be re-issuable
 * by anyone else. One collection
 * therefore serves many vaults, which collection-wide ownership could never do.
 *
 * Tokens are freely transferable (R-5): the secondary market is the only pre-maturity exit.
 */
contract SunToken is ERC1155, OwnerIsCreator {
    /**
     * Base uri for all tokens metadata
     */
    string public baseURI;

    /**
     * Vault authorised to mint and burn a given token id
     */
    mapping(uint256 tokenId => address) public issuerOf;

    /**
     * Id the next createToken() will assign. Ids start at 1, so 0 never refers to an issued token
     */
    uint256 public nextTokenId = 1;

    /**
     * Outstanding supply per token id
     */
    mapping(uint256 tokenId => uint256) public totalSupply;

    /**
     * Uri for a given token within the base uri
     */
    mapping(uint256 tokenId => string) private _tokenURIs;

    event TokenCreated(uint256 indexed tokenId, address indexed issuer);

    error NotIssuer();
    error ZeroIssuer();

    modifier onlyIssuer(uint256 id) {
        if (msg.sender != issuerOf[id]) revert NotIssuer();

        _;
    }

    constructor(string memory baseUri) {
        baseURI = baseUri;
    }

    /**
     * Create the next token id, bound to the vault that issues it, and return that id. Each id is
     * assigned exactly once, so a binding can never be replaced.
     */
    function createToken(address issuer) external onlyOwner returns (uint256 id) {
        if (issuer == address(0)) revert ZeroIssuer();

        id = nextTokenId++;
        issuerOf[id] = issuer;

        emit TokenCreated(id, issuer);
    }

    function mint(address to, uint256 id, uint256 amount) external onlyIssuer(id) {
        totalSupply[id] += amount;

        _mint(to, id, amount, "");
    }

    /**
     * Burn without requiring holder approval (R-4). The issuing vault is trusted for its own id
     * and only ever burns tokens the caller presented from their own balance.
     */
    function burn(address from, uint256 id, uint256 amount) external onlyIssuer(id) {
        totalSupply[id] -= amount;

        _burn(from, id, amount);
    }

    function setBaseURI(string memory baseUri) external onlyOwner {
        baseURI = baseUri;
    }

    function setURI(uint256 id, string memory tokenUri) external onlyOwner {
        _tokenURIs[id] = tokenUri;

        emit URI(tokenUri, id);
    }

    function uri(uint256 id) public view override returns (string memory) {
        return string(abi.encodePacked(baseURI, "/", _tokenURIs[id]));
    }
}
