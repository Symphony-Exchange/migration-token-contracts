// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Interface for TokenBurner verification
interface ITokenBurner {
    function isBurner() external pure returns (bytes4);
}

/// @title ERC20 Migrator (preloaded new tokens, burn old tokens)
/// @notice Users approve this contract on the OLD token, then call migrate(amount).
///         The contract delivers preloaded NEW tokens (1:1 amount) to the caller and
///         transfers the OLD tokens to the TokenBurner contract, atomically.
contract MigratorERC20 is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Old token (source).
    address public immutable oldToken;

    /// @notice New token (destination) from which preloaded tokens are delivered.
    address public immutable newToken;

    /// @notice TokenBurner contract where old tokens are permanently locked.
    address public immutable tokenBurner;

    /// @dev Emitted after a successful migration.
    event Migrated(address indexed user, uint256 amount);
    /// @dev Emitted when NEW tokens are deposited by the owner.
    event NewDeposited(address indexed from, uint256 amount);
    /// @dev Emitted when NEW tokens are withdrawn by the owner.
    event NewWithdrawn(address indexed to, uint256 amount);
    /// @dev Emitted when arbitrary ERC20 tokens are recovered by the owner (excluding OLD token).
    event ERC20Recovered(address indexed token, address indexed to, uint256 amount);
    /// @dev Emitted when the contract is deployed.
    event MigratorDeployed(address indexed oldToken, address indexed newToken, address indexed tokenBurner);
    /// @dev Emitted when migrations are paused.
    event MigrationsPaused(address indexed owner);
    /// @dev Emitted when migrations are unpaused.
    event MigrationsUnpaused(address indexed owner);

    error InvalidAddress();
    error IdenticalAssets();
    error InvalidTokenBurner();
    error MissingApproval();
    error NewNotPreloaded();
    error InsufficientOldBalance();
    error CannotRecoverOldOrNewToken();
    error OldTransferInvariant();
    error NewTransferInvariant();
    error ZeroAmount();

    constructor(address _owner, address _oldToken, address _newToken, address _tokenBurner) Ownable(_owner) {
        if (_oldToken == address(0) || _newToken == address(0) || _tokenBurner == address(0)) revert InvalidAddress();
        if (_oldToken == _newToken) revert IdenticalAssets();
        // Verify _tokenBurner is a valid TokenBurner contract by checking the magic value
        try ITokenBurner(_tokenBurner).isBurner() returns (bytes4 result) {
            if (result != ITokenBurner.isBurner.selector) revert InvalidTokenBurner();
        } catch {
            revert InvalidTokenBurner();
        }
        oldToken = _oldToken;
        newToken = _newToken;
        tokenBurner = _tokenBurner;
        emit MigratorDeployed(_oldToken, _newToken, _tokenBurner);
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

    /// @notice Owner deposits NEW tokens into the contract. Owner must approve this contract first.
    function depositNew(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        IERC20(newToken).safeTransferFrom(msg.sender, address(this), amount);
        emit NewDeposited(msg.sender, amount);
    }

    /// @notice Owner withdraws NEW tokens back to the owner.
    function withdrawNew(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        IERC20(newToken).safeTransfer(msg.sender, amount);
        emit NewWithdrawn(msg.sender, amount);
    }

    /// @notice Recover ERC20 tokens sent here by mistake.
    /// @dev The OLD token being migrated from cannot be recovered.
    function recoverERC20(address token, uint256 amount, address to) external onlyOwner {
        if (token == address(0) || to == address(0)) revert InvalidAddress();
        if (amount == 0) revert ZeroAmount();
        if (token == oldToken || token == newToken) revert CannotRecoverOldOrNewToken();
        IERC20(token).safeTransfer(to, amount);
        emit ERC20Recovered(token, to, amount);
    }

    // =========================
    // Migration
    // =========================

    /// @notice Migrate an amount from the old to the new token.
    /// @dev Requires:
    /// - amount > 0
    /// - Caller has approved this contract to transfer the old tokens
    /// - This contract balance on newToken >= amount (preloaded)
    function migrate(uint256 amount) external nonReentrant whenNotPaused {
        // Check for zero amount
        if (amount == 0) revert ZeroAmount();

        address _old = oldToken;
        address _new = newToken;
        address _burner = tokenBurner;

        // Verify allowance on OLD tokens (check first - more likely to fail, saves gas)
        if (IERC20(_old).allowance(msg.sender, address(this)) < amount) revert MissingApproval();

        // Verify this contract is preloaded with enough NEW tokens
        if (IERC20(_new).balanceOf(address(this)) < amount) revert NewNotPreloaded();

        // Send old tokens to burner contract and assert receipt
        uint256 oldBefore = IERC20(_old).balanceOf(_burner);
        IERC20(_old).safeTransferFrom(msg.sender, _burner, amount);
        uint256 oldAfter = IERC20(_old).balanceOf(_burner);
        if (oldAfter < oldBefore || oldAfter - oldBefore != amount) revert OldTransferInvariant();

        // Deliver new tokens and assert debit
        uint256 newBefore = IERC20(_new).balanceOf(address(this));
        IERC20(_new).safeTransfer(msg.sender, amount);
        uint256 newAfter = IERC20(_new).balanceOf(address(this));
        if (newBefore < newAfter || newBefore - newAfter != amount) revert NewTransferInvariant();

        emit Migrated(msg.sender, amount);
    }
}


