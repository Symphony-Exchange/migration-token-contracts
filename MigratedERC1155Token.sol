// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MigratedERC1155Token is ERC1155, Ownable {
    string public name;
    string public symbol;

    constructor(
        address initialOwner,
        string memory uri,
        string memory _name,
        string memory _symbol,
        uint256[] memory ids,
        uint256[] memory amounts
    )
        ERC1155(uri)
        Ownable(initialOwner)
    {
        name = _name;
        symbol = _symbol;
        require(ids.length == amounts.length, "IDs and amounts length mismatch");

        // Pre-mint all token IDs with specified amounts to owner
        if (ids.length > 0) {
            _mintBatch(initialOwner, ids, amounts, "");
        }
    }

    function setURI(string memory newuri) public onlyOwner {
        _setURI(newuri);
    }
}
