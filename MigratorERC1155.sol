// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC1155} from "openzeppelin-contracts/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Receiver} from "openzeppelin-contracts/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Interface for TokenBurner verification
interface ITokenBurner {
    function isBurner() external pure returns (bytes4);
}

/// @title ERC1155 Migrator (preloaded new tokens, burn old tokens)
/// @notice Users approve this contract on the OLD collection, then call migrate(id, amount).
///         The contract delivers the preloaded NEW tokens (same id, amount) to the caller and
///         transfers the OLD tokens to the TokenBurner contract, atomically.
contract MigratorERC1155 is Ownable, Pausable, ReentrancyGuard, IERC1155Receiver {
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
    event Migrated(address indexed user, uint256 indexed id, uint256 amount);
    /// @dev Emitted when a batch of NEW ERC1155 tokens are deposited by the owner.
    event NewBatchDeposited(address indexed from, uint256[] ids, uint256[] amounts);
    /// @dev Emitted when a batch of NEW ERC1155 tokens are withdrawn by the owner.
    event NewBatchWithdrawn(address indexed to, uint256[] ids, uint256[] amounts);
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
    error InsufficientOldBalance();
    error NewNotPreloaded();
    error MissingApproval();
    error OldTransferInvariant();
    error NewTransferInvariant();
    error ZeroAmount();
    error LengthMismatch();
    error BatchSizeExceeded();
    error EmptyBatch();
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

    /// @notice Owner pulls a batch of NEW ERC1155 tokens into the contract. Owner must have approved this contract.
    function depositNewBatch(uint256[] calldata ids, uint256[] calldata amounts) external onlyOwner {
        uint256 length = ids.length;
        if (length == 0) revert EmptyBatch();
        if (length != amounts.length) revert LengthMismatch();
        if (length > MAX_BATCH_SIZE) revert BatchSizeExceeded();
        
        IERC1155(newCollection).safeBatchTransferFrom(msg.sender, address(this), ids, amounts, "");
        emit NewBatchDeposited(msg.sender, ids, amounts);
    }

    /// @notice Owner withdraws a batch of NEW ERC1155 tokens back to the owner.
    function withdrawNewBatch(uint256[] calldata ids, uint256[] calldata amounts) external onlyOwner {
        uint256 length = ids.length;
        if (length == 0) revert EmptyBatch();
        if (length != amounts.length) revert LengthMismatch();
        if (length > MAX_BATCH_SIZE) revert BatchSizeExceeded();
        
        IERC1155(newCollection).safeBatchTransferFrom(address(this), msg.sender, ids, amounts, "");
        emit NewBatchWithdrawn(msg.sender, ids, amounts);
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

    /// @notice Migrate an ERC1155 id and amount from the old to the new collection.
    /// @dev Requires:
    /// - amount > 0
    /// - This contract has at least `amount` balance for `id` on newCollection (preloaded)
    /// - Caller has setApprovalForAll(this) on the old collection
    function migrate(uint256 id, uint256 amount) external nonReentrant whenNotPaused {
        // Check for zero amount
        if (amount == 0) revert ZeroAmount();

        address _old = oldCollection;
        address _new = newCollection;
        address _burner = tokenBurner;

        // Verify operator approval on OLD collection (check first - more likely to fail, saves gas)
        if (!IERC1155(_old).isApprovedForAll(msg.sender, address(this))) revert MissingApproval();

        // Verify this contract has sufficient NEW balance (preloaded)
        if (IERC1155(_new).balanceOf(address(this), id) < amount) revert NewNotPreloaded();

        // Send old tokens to burner contract and assert receipt
        uint256 oldBefore = IERC1155(_old).balanceOf(_burner, id);
        IERC1155(_old).safeTransferFrom(msg.sender, _burner, id, amount, "");
        uint256 oldAfter = IERC1155(_old).balanceOf(_burner, id);
        if (oldAfter < oldBefore || oldAfter - oldBefore != amount) revert OldTransferInvariant();

        // Deliver new tokens and assert debit
        uint256 newBefore = IERC1155(_new).balanceOf(address(this), id);
        IERC1155(_new).safeTransferFrom(address(this), msg.sender, id, amount, "");
        uint256 newAfter = IERC1155(_new).balanceOf(address(this), id);
        if (newBefore < newAfter || newBefore - newAfter != amount) revert NewTransferInvariant();

        emit Migrated(msg.sender, id, amount);
    }

    // =========================
    // ERC1155 Receiver
    // =========================

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external view override returns (bytes4) {
        // Only accept tokens from NEW collections to prevent accidental transfers
        if (msg.sender != newCollection) revert UnauthorizedToken();
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external view override returns (bytes4) {
        // Only accept tokens from NEW collections to prevent accidental transfers
        if (msg.sender != newCollection) revert UnauthorizedToken();
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        // ERC165 (IERC165)
        return interfaceId == 0x01ffc9a7 || interfaceId == type(IERC1155Receiver).interfaceId;
    }
}
