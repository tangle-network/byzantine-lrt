// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ERC7535MultiRewardVault as ByzantineVault} from "dependencies/byzantine-contracts/src/vault/ERC7535MultiRewardVault.sol";
import {MultiAssetDelegation, MULTI_ASSET_DELEGATION_CONTRACT} from "./MultiAssetDelegation.sol";

/// @title TangleByzantineVault
/// @notice A Byzantine vault implementation that delegates assets to Tangle operators
/// @dev Integrates Byzantine's ERC7535 vault with Tangle's restaking infrastructure
/// @dev Withdrawal process:
///      1. User calls scheduleUnstake(amount)
///      2. After unstaking delay, user calls scheduleWithdraw(amount)
///      3. After withdrawal delay, user calls withdraw(amount)
contract TangleByzantineVault is ByzantineVault {
    /* ============ Events ============ */
    
    event OperatorSet(bytes32 indexed operator);
    event BlueprintSelectionSet(uint64[] blueprintSelection);
    event WithdrawScheduled(address indexed owner, uint256 assets, uint256 scheduledAt);
    event UnstakeScheduled(address indexed owner, uint256 assets, uint256 scheduledAt);
    event UnstakeCancelled(address indexed owner, uint256 assets);
    event WithdrawCancelled(address indexed owner, uint256 assets);
    event AssetsDelegated(address indexed owner, uint256 assets);

    /* ============ Errors ============ */
    
    error InvalidOperator();
    error InvalidBlueprintSelection();
    error DelegationFailed();
    error UnstakeNotScheduled();
    error WithdrawNotScheduled();
    error InsufficientUnstakeAmount();
    error InsufficientWithdrawAmount();
    error WithdrawAmountExceedsScheduled();
    error UnstakeAmountExceedsBalance();
    error NoUnstakeToCancel();
    error NoWithdrawToCancel();
    error DelegationNotPossible();
    error InvalidState();

    /* ============ Types ============ */

    /// @notice Represents the state of an unstaking request
    enum UnstakeState {
        None,       // No unstake requested
        Scheduled,  // Unstake has been scheduled
        Executed    // Unstake has been executed
    }

    /// @notice Represents the state of a withdrawal request
    enum WithdrawState {
        None,       // No withdrawal requested
        Scheduled,  // Withdrawal has been scheduled
        Ready       // Withdrawal is ready to be executed
    }

    /// @notice Tracks an unstaking request
    struct UnstakeRequest {
        uint256 amount;
        uint256 timestamp;
        UnstakeState state;
    }

    /// @notice Tracks a withdrawal request
    struct WithdrawRequest {
        uint256 amount;
        uint256 timestamp;
        WithdrawState state;
    }

    /* ============ State Variables ============ */
    
    /// @notice The operator to delegate assets to
    bytes32 public operator;
    
    /// @notice The blueprint selection for delegations
    uint64[] public blueprintSelection;

    /// @notice Tracks unstaking requests per address
    /// @dev owner => UnstakeRequest
    mapping(address => UnstakeRequest) public unstakeRequests;

    /// @notice Tracks withdrawal requests per address
    /// @dev owner => WithdrawRequest
    mapping(address => WithdrawRequest) public withdrawRequests;

    /* ============ Constructor ============ */

    /// @notice Initializes the vault with an oracle and operator
    /// @param _oracle The price oracle address
    /// @param _operator The operator to delegate to
    /// @param _blueprintSelection The blueprint selection for delegations
    function initialize(
        address _oracle,
        bytes32 _operator,
        uint64[] memory _blueprintSelection
    ) external initializer {
        if (_operator == bytes32(0)) revert InvalidOperator();
        if (_blueprintSelection.length == 0) revert InvalidBlueprintSelection();

        __ERC7535MultiRewardVault_init(_oracle);
        
        operator = _operator;
        blueprintSelection = _blueprintSelection;

        emit OperatorSet(_operator);
        emit BlueprintSelectionSet(_blueprintSelection);
    }

    /* ============ External Functions ============ */

    /// @notice Schedule unstaking of assets from the operator
    /// @param assets Amount of assets to unstake
    /// @dev User must have sufficient shares to cover the unstake amount
    function scheduleUnstake(uint256 assets) external {
        // Verify user has enough shares and valid amount
        uint256 maxAssets = maxWithdraw(msg.sender);
        if (assets > maxAssets) revert UnstakeAmountExceedsBalance();
        if (assets == 0) revert InsufficientUnstakeAmount();

        MULTI_ASSET_DELEGATION_CONTRACT.scheduleDelegatorUnstake(
            operator,
            0, // Native asset
            address(0),
            assets
        );

        unstakeRequests[msg.sender] = UnstakeRequest({
            amount: assets,
            timestamp: block.timestamp,
            state: UnstakeState.Scheduled
        });

        emit UnstakeScheduled(msg.sender, assets, block.timestamp);
    }

    /// @notice Cancel a scheduled unstake, keeping assets delegated
    function cancelUnstake() external {
        UnstakeRequest storage request = unstakeRequests[msg.sender];
        if (request.state != UnstakeState.Scheduled) revert NoUnstakeToCancel();

        MULTI_ASSET_DELEGATION_CONTRACT.cancelDelegatorUnstake(
            operator,
            0,
            address(0),
            request.amount
        );

        uint256 amount = request.amount;
        delete unstakeRequests[msg.sender];
        
        emit UnstakeCancelled(msg.sender, amount);
    }

    /// @notice Schedule withdrawal of assets from the vault
    /// @param assets Amount of assets to withdraw
    /// @dev User must have executed unstake for >= amount
    function scheduleWithdraw(uint256 assets) external {
        UnstakeRequest storage unstake = unstakeRequests[msg.sender];
        if (unstake.state != UnstakeState.Executed) revert InvalidState();
        if (unstake.amount < assets) revert InsufficientUnstakeAmount();
        if (assets == 0) revert InsufficientWithdrawAmount();
        
        MULTI_ASSET_DELEGATION_CONTRACT.scheduleWithdraw(
            0,
            address(0),
            assets
        );

        withdrawRequests[msg.sender] = WithdrawRequest({
            amount: assets,
            timestamp: block.timestamp,
            state: WithdrawState.Scheduled
        });

        // Update unstake request amount
        unstake.amount -= assets;
        if (unstake.amount == 0) {
            delete unstakeRequests[msg.sender];
        }

        emit WithdrawScheduled(msg.sender, assets, block.timestamp);
    }

    /// @notice Cancel a scheduled withdrawal and re-delegate assets
    function cancelWithdrawAndRedelegate() external {
        WithdrawRequest storage request = withdrawRequests[msg.sender];
        if (request.state != WithdrawState.Scheduled) revert NoWithdrawToCancel();

        // Cancel the withdrawal
        MULTI_ASSET_DELEGATION_CONTRACT.cancelWithdraw(
            0,
            address(0),
            request.amount
        );

        // Re-delegate the assets
        try MULTI_ASSET_DELEGATION_CONTRACT.delegate(
            operator,
            0,
            address(0),
            request.amount,
            blueprintSelection
        ) {
            emit AssetsDelegated(msg.sender, request.amount);
        } catch {
            revert DelegationNotPossible();
        }

        uint256 amount = request.amount;
        delete withdrawRequests[msg.sender];
        
        emit WithdrawCancelled(msg.sender, amount);
    }

    /* ============ Internal Functions ============ */

    /// @dev Override _withdraw to handle the complete withdrawal process
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        WithdrawRequest storage withdrawal = withdrawRequests[owner];
        if (withdrawal.state != WithdrawState.Scheduled) revert WithdrawNotScheduled();
        if (withdrawal.amount < assets) revert InsufficientWithdrawAmount();

        // Execute withdrawal
        MULTI_ASSET_DELEGATION_CONTRACT.executeWithdraw();

        // Update withdrawal request
        withdrawal.amount -= assets;
        if (withdrawal.amount == 0) {
            delete withdrawRequests[owner];
        }

        // Perform standard ERC7535 withdrawal
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /// @dev Override _deposit to delegate assets to Tangle operator
    /// @dev Ensures that:
    ///      1. Standard deposit is completed first
    ///      2. Assets are delegated to the operator
    ///      3. Reverts if delegation fails
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        // First perform standard ERC7535 deposit
        super._deposit(caller, receiver, assets, shares);

        // Then delegate the assets to the operator through Tangle
        try MULTI_ASSET_DELEGATION_CONTRACT.delegate(
            operator,
            0, // Native asset
            address(0), // No token address for native asset
            assets,
            blueprintSelection
        ) {
            // Delegation successful
        } catch {
            revert DelegationFailed();
        }
    }

    /// @dev Override to ensure contract can receive ETH
    receive() external payable override {}

    function getUnstakeRequest(address user) external view returns (
        uint256 amount,
        uint256 timestamp,
        UnstakeState state
    ) {
        UnstakeRequest memory request = unstakeRequests[user];
        return (request.amount, request.timestamp, request.state);
    }

    function getWithdrawRequest(address user) external view returns (
        uint256 amount,
        uint256 timestamp,
        WithdrawState state
    ) {
        WithdrawRequest memory request = withdrawRequests[user];
        return (request.amount, request.timestamp, request.state);
    }
}