// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { ERC1155 } from "lib/solmate/src/tokens/ERC1155.sol";
import { OwnerIsCreator } from "lib/chainlink/contracts/src/v0.8/shared/access/OwnerIsCreator.sol";

// TODO: CCIP support
// https://github.com/smartcontractkit/ccip-starter-kit-foundry/blob/main/src/ProgrammableTokenTransfers.sol

contract SunToken is ERC1155, OwnerIsCreator {

    /**
     * Base uri for all tokens metadata
     */
    string public baseURI;

    /**
     * Uri for a given token within the base uri
     */
    mapping(uint256 tokenId => string) private _tokenURIs;

    constructor(string memory baseUri) {
        baseURI = baseUri;
    }

    function mint(
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data,
        string memory tokenUri
    ) external onlyOwner {
        _mint(to, id, amount, data);
        _tokenURIs[id] = tokenUri;

        emit URI(tokenUri, id);
    }

    function mintBatch(
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data,
        string[] memory tokenUris
    ) external onlyOwner {
        _batchMint(to, ids, amounts, data);
        for (uint256 i = 0; i < ids.length; ++i) {
            _tokenURIs[ids[i]] = tokenUris[i];

            emit URI(tokenUris[i], ids[i]);
        }
    }

    function burn(address from, uint256 id, uint256 amount) external onlyOwner {
        require(
            from == msg.sender || isApprovedForAll[from][msg.sender],
            "ERC1155: missing approval for all"
        );

        _burn(from, id, amount);
    }

    function burnBatch(address from, uint256[] memory ids, uint256[] memory amounts) external onlyOwner {
        require(
            from == msg.sender || isApprovedForAll[from][msg.sender],
            "ERC1155: missing approval for all"
        );

        _batchBurn(from, ids, amounts);
    }

    function setBaseURI(string memory baseUri) external onlyOwner {
        baseURI = baseUri;
    }

    function setURI(uint256 tokenId, string memory tokenUri) external onlyOwner {
        tokenURIs[tokenId] = tokenUri;
        emit URI(tokenUri, tokenId);
    }

    function uri(uint256 tokenId) public view override returns (string memory) {
        string memory tokenURI = _tokenURIs[tokenId];
        return string(abi.encodePacked(baseURI, "/", tokenURI, ".json"));
    }
}
