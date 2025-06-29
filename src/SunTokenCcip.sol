// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { ERC1155 } from "lib/solmate/src/tokens/ERC1155.sol";
import { ReentrancyGuard } from "lib/solmate/src/utils/ReentrancyGuard.sol";
import { OwnerIsCreator } from "lib/chainlink/contracts/src/v0.8/shared/access/OwnerIsCreator.sol";
import { LinkTokenInterface } from "lib/chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";
import { Client } from "lib/chainlink-ccip/chains/evm/contracts/libraries/Client.sol";
import { IRouterClient } from "lib/chainlink-ccip/chains/evm/contracts/interfaces/IRouterClient.sol";
import { IAny2EVMMessageReceiver } from "lib/chainlink-ccip/chains/evm/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import { Withdraw } from "./utils/Withdraw.sol";

/**
 * THIS IS AN EXAMPLE CONTRACT THAT USES HARDCODED VALUES FOR CLARITY.
 * THIS IS AN EXAMPLE CONTRACT THAT USES UN-AUDITED CODE.
 * DO NOT USE THIS CODE IN PRODUCTION.
 *
 * A CCIP enabled version of the SunToken.sol
 * Forked from: https://cll-devrel.gitbook.io/tokenized-rwa-bootcamp-2024/day-1/exercise-1-cross-chain-real-estate
 */
contract SunTokenCcip is ERC1155, OwnerIsCreator, Withdraw, IAny2EVMMessageReceiver, ReentrancyGuard {
    enum PayFeesIn {
        Native,
        LINK
    }

    error InvalidRouter(address router);
    error NotEnoughBalanceForFees(uint256 currentBalance, uint256 calculatedFees);
    error ChainNotEnabled(uint64 chainSelector);
    error SenderNotEnabled(address sender);
    error OperationNotAllowedOnCurrentChain(uint64 chainSelector);

    struct XNftDetails {
        address xNftAddress;
        bytes ccipExtraArgsBytes;
    }

    /**
     * Base uri for all tokens metadata
     */
    string public baseURI;

    /**
     * CCIP params for the chain token is deployed on
     */
    // router address on this chain
    IRouterClient internal immutable ccipRouter;
    // link token address on this chain (used for gas only)
    LinkTokenInterface internal immutable linkToken;
    // this chain
    uint64 private immutable currentChainSelector;

    /**
     * Uri for a given token within the base uri
     */
    mapping(uint256 tokenId => string) private _tokenURIs;

    /**
     * CCIP registry with all supported destination networks, with counterpart contract address and tx settings for the other side
     */
    mapping(uint64 destChainSelector => XNftDetails xNftDetailsPerChain) public sChains;

    event ChainEnabled(uint64 chainSelector, address xNftAddress, bytes ccipExtraArgs);
    event ChainDisabled(uint64 chainSelector);
    event CrossChainSent(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes data,
        uint64 sourceChainSelector,
        uint64 destinationChainSelector
    );
    event CrossChainReceived(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes data,
        uint64 sourceChainSelector,
        uint64 destinationChainSelector
    );

    modifier onlyRouter() {
        if (msg.sender != address(ccipRouter)) {
            revert InvalidRouter(msg.sender);
        }
        _;
    }

    modifier onlyEnabledChain(uint64 _chainSelector) {
        if (sChains[_chainSelector].xNftAddress == address(0)) {
            revert ChainNotEnabled(_chainSelector);
        }
        _;
    }

    modifier onlyEnabledSender(uint64 _chainSelector, address _sender) {
        if (sChains[_chainSelector].xNftAddress != _sender) {
            revert SenderNotEnabled(_sender);
        }
        _;
    }

    modifier onlyOtherChains(uint64 _chainSelector) {
        if (_chainSelector == currentChainSelector) {
            revert OperationNotAllowedOnCurrentChain(_chainSelector);
        }
        _;
    }

    constructor(string memory baseUri, address ccipRouterAddress, address linkTokenAddress, uint64 chainSelector) {
        baseURI = baseUri;

        ccipRouter = IRouterClient(ccipRouterAddress);
        linkToken = LinkTokenInterface(linkTokenAddress);
        currentChainSelector = chainSelector;
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
        _tokenURIs[tokenId] = tokenUri;
        emit URI(tokenUri, tokenId);
    }

    function uri(uint256 tokenId) public view override returns (string memory) {
        string memory tokenURI = _tokenURIs[tokenId];
        return string(abi.encodePacked(baseURI, "/", tokenURI));
    }

    /**
     * Enable chain as source/destination for cross-chain transfers
     */
    function enableChain(uint64 chainSelector, address xNftAddress, bytes memory ccipExtraArgs)
        external
        onlyOwner
        onlyOtherChains(chainSelector)
    {
        sChains[chainSelector] = XNftDetails({xNftAddress: xNftAddress, ccipExtraArgsBytes: ccipExtraArgs});

        emit ChainEnabled(chainSelector, xNftAddress, ccipExtraArgs);
    }

    /**
     * Disable chain for cross-chain transfers with this contract deployment
     */
    function disableChain(uint64 chainSelector) external onlyOwner onlyOtherChains(chainSelector) {
        delete sChains[chainSelector];

        emit ChainDisabled(chainSelector);
    }

    /**
     * Send tokens via CCIP to destination chain
     */
    function crossChainTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data,
        uint64 destinationChainSelector,
        PayFeesIn payFeesIn
    ) external nonReentrant onlyEnabledChain(destinationChainSelector) returns (bytes32 messageId) {
        string memory tokenUri = uri(id);
        _burn(from, id, amount);

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(sChains[destinationChainSelector].xNftAddress),
            data: abi.encode(from, to, id, amount, data, tokenUri),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: sChains[destinationChainSelector].ccipExtraArgsBytes,
            feeToken: payFeesIn == PayFeesIn.LINK ? address(linkToken) : address(0)
        });

        // Get the fee required to send the CCIP message
        uint256 fees = ccipRouter.getFee(destinationChainSelector, message);

        if (payFeesIn == PayFeesIn.LINK) {
            if (fees > linkToken.balanceOf(address(this))) {
                revert NotEnoughBalanceForFees(linkToken.balanceOf(address(this)), fees);
            }

            // Approve the Router to transfer LINK tokens on contract's behalf. It will spend the fees in LINK
            linkToken.approve(address(ccipRouter), fees);

            // Send the message through the router and store the returned message ID
            messageId = ccipRouter.ccipSend(destinationChainSelector, message);
        } else {
            if (fees > address(this).balance) {
                revert NotEnoughBalanceForFees(address(this).balance, fees);
            }

            // Send the message through the router and store the returned message ID
            messageId = ccipRouter.ccipSend{value: fees}(destinationChainSelector, message);
        }

        emit CrossChainSent(from, to, id, amount, data, currentChainSelector, destinationChainSelector);
    }

    /**
     * Internal CCIP check
     */
    function supportsInterface(bytes4 interfaceId) public view override(ERC1155) returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || super.supportsInterface(interfaceId);
    }

    /**
     * Receive CCIP mint action from another chain
     */
    /// @inheritdoc IAny2EVMMessageReceiver
    function ccipReceive(Client.Any2EVMMessage calldata message)
        external
        virtual
        override
        onlyRouter
        nonReentrant
        onlyEnabledChain(message.sourceChainSelector)
        onlyEnabledSender(message.sourceChainSelector, abi.decode(message.sender, (address)))
    {
        uint64 sourceChainSelector = message.sourceChainSelector;
        (address from, address to, uint256 id, uint256 amount, bytes memory data, string memory tokenUri) =
            abi.decode(message.data, (address, address, uint256, uint256, bytes, string));

        _mint(to, id, amount, data);
        _tokenURIs[id] = tokenUri;

        emit URI(tokenUri, id);

        emit CrossChainReceived(from, to, id, amount, data, sourceChainSelector, currentChainSelector);
    }
}
