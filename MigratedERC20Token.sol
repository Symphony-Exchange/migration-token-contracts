// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MigratedERC20Token is ERC20, Ownable {
    uint8 private immutable _decimals;

    constructor(
        address initialOwner,
        string memory name,
        string memory symbol,
        uint8 decimals_,
        uint256 totalSupply
    )
        ERC20(name, symbol)
        Ownable(initialOwner)
    {
        _decimals = decimals_;
        _mint(initialOwner, totalSupply * (10 ** decimals_)); // Mint once, no further minting
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}