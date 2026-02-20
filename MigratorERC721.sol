// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeERC721} from "./utils/SafeERC721.sol";

/// @notice Interface for TokenBurner verification
interface ITokenBurner {
    function isBurner() external pure returns (bytes4);
}

/// @title ERC721 MigratorERC721 (preloaded new tokens, burn old tokens)
/// @notice Users approve this contract on the OLD collection, then call migrate(tokenId).
///         The contract delivers the preloaded NEW token (same id) to the caller and
///         transfers the OLD token to the TokenBurner contract, atomically.
contract MigratorERC721 is Ownable, Pausable, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    /// @notice Maximum batch size to prevent DOS attacks
    uint256 public constant MAX_BATCH_SIZE = 200;

    /// @notice Old collection (source).
    address public immutable oldCollection;

    /// @notice New collection (destination) from which preloaded tokens are delivered.
    address public immutable newCollection;

    /// @notice TokenBurner contract where old tokens are permanently locked.
    address public immutable tokenBurner;

    /// @dev Emitted after a successful migration.
    event Migrated(address indexed user, uint256 indexed tokenId);
    /// @dev Emitted when a batch of NEW ERC721 tokens are deposited by the owner.
    event NewBatchDeposited(address indexed from, uint256[] tokenIds);
    /// @dev Emitted when a batch of NEW ERC721 tokens are withdrawn by the owner.
    event NewBatchWithdrawn(address indexed to, uint256[] tokenIds);
    /// @dev Emitted when arbitrary ERC20 tokens are recovered by the owner.
    event ERC20Recovered(address indexed token, address indexed to, uint256 amount);
    /// @dev Emitted when the contract is deployed.
    event MigratorDeployed(address indexed oldCollection, address indexed newCollection, address indexed tokenBurner);
    /// @dev Emitted when migrations are paused.
    event MigrationsPaused(address indexed owner);
    /// @dev Emitted when migrations are unpaused.
    event MigrationsUnpaused(address indexed owner);

    error InvalidAddress();
    error IdenticalAssets();
    error InvalidTokenBurner();
    error NotOldOwner();
    error NewNotPreloaded();
    error MissingApproval();
    error OldTransferInvariant();
    error NewTransferInvariant();
    error BatchSizeExceeded();
    error EmptyBatch();
    error ZeroAmount();
    error UnauthorizedToken();

    constructor(address _owner, address _oldCollection, address _newCollection, address _tokenBurner) Ownable(_owner) {
        if (_oldCollection == address(0) || _newCollection == address(0) || _tokenBurner == address(0)) revert InvalidAddress();
        if (_oldCollection == _newCollection) revert IdenticalAssets();
        // Verify _tokenBurner is a valid TokenBurner contract by checking the magic value
        try ITokenBurner(_tokenBurner).isBurner() returns (bytes4 result) {
            if (result != ITokenBurner.isBurner.selector) revert InvalidTokenBurner();
        } catch {
            revert InvalidTokenBurner();
        }
        oldCollection = _oldCollection;
        newCollection = _newCollection;
        tokenBurner = _tokenBurner;
        emit MigratorDeployed(_oldCollection, _newCollection, _tokenBurner);
    }

    // =========================
    // Admin
    // =========================

    /// @notice Pause migrations.
    function pause() external onlyOwner {
        _pause();
        emit MigrationsPaused(msg.sender);
    }

    /// @notice Unpause migrations.
    function unpause() external onlyOwner {
        _unpause();
        emit MigrationsUnpaused(msg.sender);
    }

    /// @notice Owner pulls a batch of NEW tokens into the contract. Owner must have approved this contract.
    function depositNewBatch(uint256[] calldata tokenIds) external onlyOwner {
        uint256 length = tokenIds.length;
        if (length == 0) revert EmptyBatch();
        if (length > MAX_BATCH_SIZE) revert BatchSizeExceeded();
        
        for (uint256 i = 0; i < length;) {
            SafeERC721.safeTransferFrom(IERC721(newCollection), msg.sender, address(this), tokenIds[i]);
            unchecked {
                ++i;
            }
        }
        emit NewBatchDeposited(msg.sender, tokenIds);
    }

    /// @notice Owner withdraws a batch of NEW tokens back to the owner.
    function withdrawNewBatch(uint256[] calldata tokenIds) external onlyOwner {
        uint256 length = tokenIds.length;
        if (length == 0) revert EmptyBatch();
        if (length > MAX_BATCH_SIZE) revert BatchSizeExceeded();
        
        for (uint256 i = 0; i < length;) {
            SafeERC721.safeTransferFrom(IERC721(newCollection), address(this), msg.sender, tokenIds[i]);
            unchecked {
                ++i;
            }
        }
        emit NewBatchWithdrawn(msg.sender, tokenIds);
    }

    /// @notice Recover ERC20 tokens sent here by mistake.
    function recoverERC20(address token, uint256 amount, address to) external onlyOwner {
        if (token == address(0) || to == address(0)) revert InvalidAddress();
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(to, amount);
        emit ERC20Recovered(token, to, amount);
    }

    // =========================
    // Migration
    // =========================

    /// @notice Migrate a token id from the old to the new collection.
    /// @dev Requires:
    /// - Caller owns tokenId on oldCollection
    /// - This contract owns the same tokenId on newCollection (preloaded)
    /// - Caller has approved this contract to transfer the old token
    function migrate(uint256 tokenId) external nonReentrant whenNotPaused {
        address _old = oldCollection;
        address _new = newCollection;
        address _burner = tokenBurner;

        // Verify caller owns the OLD token id
        if (IERC721(_old).ownerOf(tokenId) != msg.sender) revert NotOldOwner();

        // Verify this contract owns the NEW token id (preloaded)
        if (IERC721(_new).ownerOf(tokenId) != address(this)) revert NewNotPreloaded();

        // Verify approval on OLD token id
        // Either specific approval or operator approval
        if (
            IERC721(_old).getApproved(tokenId) != address(this) &&
            !IERC721(_old).isApprovedForAll(msg.sender, address(this))
        ) {
            revert MissingApproval();
        }

        // Send old NFT to burner contract and assert ownership
        SafeERC721.safeTransferFrom(IERC721(_old), msg.sender, _burner, tokenId);
        if (IERC721(_old).ownerOf(tokenId) != _burner) revert OldTransferInvariant();

        // Deliver new NFT and assert ownership
        SafeERC721.safeTransferFrom(IERC721(_new), address(this), msg.sender, tokenId);
        if (IERC721(_new).ownerOf(tokenId) != msg.sender) revert NewTransferInvariant();

        emit Migrated(msg.sender, tokenId);
    }

    /// @notice Migrate multiple token ids from the old to the new collection in one transaction.
    /// @dev Batch operations are gas efficient for multiple NFTs. Max batch size enforced.
    function migrateBatch(uint256[] calldata tokenIds) external nonReentrant whenNotPaused {
        uint256 length = tokenIds.length;
        if (length == 0) revert EmptyBatch();
        if (length > MAX_BATCH_SIZE) revert BatchSizeExceeded();

        address _old = oldCollection;
        address _new = newCollection;
        address _burner = tokenBurner;

        for (uint256 i = 0; i < length;) {
            uint256 tokenId = tokenIds[i];

            // Verify caller owns the OLD token id
            if (IERC721(_old).ownerOf(tokenId) != msg.sender) revert NotOldOwner();

            // Verify this contract owns the NEW token id (preloaded)
            if (IERC721(_new).ownerOf(tokenId) != address(this)) revert NewNotPreloaded();

            // Verify approval on OLD token id
            if (
                IERC721(_old).getApproved(tokenId) != address(this) &&
                !IERC721(_old).isApprovedForAll(msg.sender, address(this))
            ) {
                revert MissingApproval();
            }

            // Send old NFT to burner contract and assert ownership
            SafeERC721.safeTransferFrom(IERC721(_old), msg.sender, _burner, tokenId);
            if (IERC721(_old).ownerOf(tokenId) != _burner) revert OldTransferInvariant();

            // Deliver new NFT and assert ownership
            SafeERC721.safeTransferFrom(IERC721(_new), address(this), msg.sender, tokenId);
            if (IERC721(_new).ownerOf(tokenId) != msg.sender) revert NewTransferInvariant();

            emit Migrated(msg.sender, tokenId);

            unchecked {
                ++i;
            }
        }
    }

    // =========================
    // ERC721 Receiver
    // =========================

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external view override returns (bytes4) {
        // Only accept tokens from NEW collections to prevent accidental transfers
        if (msg.sender != newCollection) revert UnauthorizedToken();
        return IERC721Receiver.onERC721Received.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        // ERC165 (IERC165), IERC721Receiver
        return interfaceId == 0x01ffc9a7 
            || interfaceId == type(IERC721Receiver).interfaceId;
    }
}


