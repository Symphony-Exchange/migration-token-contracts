# Migration Token Contracts

Solidity contracts used by the Asset Migration interface to deploy new EVM-native tokens on Sei Network.

## Token Contracts

### MigratedERC20Token.sol

Standard ERC-20 token with configurable name, symbol, decimals, and total supply. The entire supply is minted to the deployer on construction. Built on OpenZeppelin ERC20 and Ownable.

### MigratedERC721Token.sol

Standard ERC-721 NFT collection with configurable name, symbol, base URI, and max supply. Supports batch minting (up to 200 per transaction) by the contract owner. Built on OpenZeppelin ERC721 and Ownable.

### MigratedERC1155Token.sol

Standard ERC-1155 multi-token with configurable URI, name, symbol, and pre-minted token IDs/amounts. All specified token types are batch-minted to the deployer on construction. Built on OpenZeppelin ERC1155 and Ownable.

## ABI & Bytecode

Pre-compiled ABI definitions and deployment bytecode for each contract are located in `frontend/src/bytecode/`:

| File | Contents |
|------|----------|
| `migratedERC20Token.js` | ABI and bytecode for MigratedERC20Token |
| `migratedERC721Token.js` | ABI and bytecode for MigratedERC721Token |
| `migratedERC1155Token.js` | ABI and bytecode for MigratedERC1155Token |

These files export two constants each — the contract ABI (used for interacting with deployed instances) and the bytecode (used for deploying new instances directly from the frontend).

## Disclaimer

These contracts are generic reference implementations provided for convenience. They have not been independently audited and carry no guarantees regarding security. If your token requires custom functionality or non-standard behavior, you should deploy your own contract instead.
