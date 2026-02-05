// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MigratedERC721Token is ERC721, Ownable {
    string private _baseTokenURI;
    uint256 private _nextTokenId;
    uint256 public immutable maxSupply;

    constructor(
        address initialOwner,
        string memory name,
        string memory symbol,
        string memory baseURI,
        uint256 _maxSupply
    )
        ERC721(name, symbol)
        Ownable(initialOwner)
    {
        _baseTokenURI = baseURI;
        _nextTokenId = 0;
        maxSupply = _maxSupply;
        // No minting in constructor - use batchMint after deployment
    }

    /// @notice Batch mint NFTs to a recipient (owner only)
    /// @param to Recipient address
    /// @param amount Number of NFTs to mint
    function batchMint(address to, uint256 amount) external onlyOwner {
        require(amount <= 200, "Max 200 per batch");
        require(_nextTokenId + amount <= maxSupply, "Would exceed max supply");

        uint256 startId = _nextTokenId;
        for (uint256 i = 0; i < amount; i++) {
            _mint(to, startId + i);
        }
        _nextTokenId = startId + amount;
    }

    /// @notice Get next token ID that will be minted
    function nextTokenId() external view returns (uint256) {
        return _nextTokenId;
    }

    /// @notice Get remaining mintable supply
    function remainingSupply() external view returns (uint256) {
        return maxSupply - _nextTokenId;
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

 
}