// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721Receiver} from "openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155Receiver} from "openzeppelin-contracts/contracts/token/ERC1155/IERC1155Receiver.sol";

/// @title TokenBurner
/// @notice An immutable contract that accepts and permanently locks tokens.
/// @dev This contract has no owner, no functions to withdraw tokens, and serves
///      as an irreversible destination for migrated old tokens.
///      Since address(0) doesn't exist on SEI, this provides an equivalent "burn" mechanism.
contract TokenBurner is IERC721Receiver, IERC1155Receiver {
    /// @dev Emitted when tokens are received and locked forever
    event TokensBurned(address indexed token, address indexed from, uint256 amount);
    event NFTBurned(address indexed token, address indexed from, uint256 indexed tokenId);
    event SemiFungibleBurned(address indexed token, address indexed from, uint256 indexed id, uint256 amount);

    /// @notice Constructor is empty - no configuration needed
    constructor() {}

    /// @dev Accept ERC721 tokens
    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata
    ) external override returns (bytes4) {
        emit NFTBurned(msg.sender, from, tokenId);
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @dev Accept ERC1155 single transfers
    function onERC1155Received(
        address,
        address from,
        uint256 id,
        uint256 amount,
        bytes calldata
    ) external override returns (bytes4) {
        emit SemiFungibleBurned(msg.sender, from, id, amount);
        return IERC1155Receiver.onERC1155Received.selector;
    }

    /// @dev Accept ERC1155 batch transfers
    function onERC1155BatchReceived(
        address,
        address from,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata
    ) external override returns (bytes4) {
        uint256 length = ids.length;
        for (uint256 i = 0; i < length; i++) {
            emit SemiFungibleBurned(msg.sender, from, ids[i], amounts[i]);
        }
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    /// @dev Support ERC165 interface detection
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return
            interfaceId == type(IERC721Receiver).interfaceId ||
            interfaceId == type(IERC1155Receiver).interfaceId ||
            interfaceId == 0x01ffc9a7; // ERC165
    }

    /// @notice Returns a magic value to verify this is a valid TokenBurner contract
    /// @dev Returns the function selector, similar to ERC721Receiver/ERC1155Receiver pattern.
    ///      Migrator contracts call this during construction to ensure they are configured
    ///      with a real TokenBurner and not an arbitrary address.
    function isBurner() external pure returns (bytes4) {
        return this.isBurner.selector;
    }

    /// @notice Fallback to accept ERC20 tokens and ETH
    /// @dev ERC20 tokens sent here are permanently locked
    receive() external payable {
        emit TokensBurned(address(0), msg.sender, msg.value);
    }
}

