// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {TangleByzantineVault} from "../src/TangleByzantineVault.sol";
import {MultiAssetDelegation} from "../src/MultiAssetDelegation.sol";
import {IOracle} from "dependencies/byzantine-contracts/src/interfaces/IOracle.sol";

contract MockOracle is IOracle {
    function getPrice(address) external pure returns (uint256) {
        return 1e18; // 1:1 price ratio for simplicity
    }
}

contract MockMultiAssetDelegation is MultiAssetDelegation {
    bool public shouldRevert;
    
    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function delegate(
        bytes32,
        uint256,
        address,
        uint256,
        uint64[] memory
    ) external {
        if (shouldRevert) revert("Delegation failed");
    }

    function scheduleDelegatorUnstake(
        bytes32,
        uint256,
        address,
        uint256
    ) external {
        if (shouldRevert) revert("Unstake scheduling failed");
    }

    function cancelDelegatorUnstake(
        bytes32,
        uint256,
        address,
        uint256
    ) external {
        if (shouldRevert) revert("Unstake cancellation failed");
    }

    function executeDelegatorUnstake() external {
        if (shouldRevert) revert("Unstake execution failed");
    }

    function scheduleWithdraw(
        uint256,
        address,
        uint256
    ) external {
        if (shouldRevert) revert("Withdraw scheduling failed");
    }

    function executeWithdraw() external {
        if (shouldRevert) revert("Withdraw execution failed");
    }

    function cancelWithdraw(
        uint256,
        address,
        uint256
    ) external {
        if (shouldRevert) revert("Withdraw cancellation failed");
    }

    function joinOperators(uint256) external pure {}
    function scheduleLeaveOperators() external pure {}
    function cancelLeaveOperators() external pure {}
    function executeLeaveOperators() external pure {}
    function operatorBondMore(uint256) external pure {}
    function scheduleOperatorUnstake(uint256) external pure {}
    function executeOperatorUnstake() external pure {}
    function cancelOperatorUnstake() external pure {}
    function goOffline() external pure {}
    function goOnline() external pure {}
    function deposit(uint256, address, uint256, uint8) external pure {}
}

contract TangleByzantineVaultTest is Test {
    TangleByzantineVault public vault;
    MockOracle public oracle;
    MockMultiAssetDelegation public mockDelegation;
    
    bytes32 public constant OPERATOR = bytes32(uint256(1));
    uint64[] public blueprintSelection;
    address public alice = address(0x1);
    address public bob = address(0x2);
    uint256 public constant DEPOSIT_AMOUNT = 1 ether;

    event OperatorSet(bytes32 indexed operator);
    event BlueprintSelectionSet(uint64[] blueprintSelection);
    event WithdrawScheduled(address indexed owner, uint256 assets, uint256 scheduledAt);
    event UnstakeScheduled(address indexed owner, uint256 assets, uint256 scheduledAt);
    event UnstakeCancelled(address indexed owner, uint256 assets);
    event WithdrawCancelled(address indexed owner, uint256 assets);
    event AssetsDelegated(address indexed owner, uint256 assets);

    function setUp() public {
        // Deploy mocks
        oracle = new MockOracle();
        mockDelegation = new MockMultiAssetDelegation();
        
        // Setup blueprint selection
        blueprintSelection.push(1);
        
        // Deploy vault with mocks
        vm.etch(address(0x822), address(mockDelegation).code);
        vault = new TangleByzantineVault();
        vault.initialize(address(oracle), OPERATOR, blueprintSelection);

        // Fund test accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function test_Initialize() public {
        assertEq(vault.operator(), OPERATOR);
        assertEq(vault.blueprintSelection(0), blueprintSelection[0]);
    }

    function testFuzz_Initialize_InvalidOperator(bytes32 invalidOperator) public {
        vm.assume(invalidOperator == bytes32(0));
        
        vault = new TangleByzantineVault();
        vm.expectRevert(TangleByzantineVault.InvalidOperator.selector);
        vault.initialize(address(oracle), invalidOperator, blueprintSelection);
    }

    function test_Deposit() public {
        vm.startPrank(alice);
        vault.deposit{value: DEPOSIT_AMOUNT}(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        assertEq(address(vault).balance, DEPOSIT_AMOUNT);
        assertEq(vault.balanceOf(alice), DEPOSIT_AMOUNT);
    }

    function test_DepositFailsOnDelegation() public {
        MockMultiAssetDelegation(address(0x822)).setShouldRevert(true);
        
        vm.startPrank(alice);
        vm.expectRevert(TangleByzantineVault.DelegationFailed.selector);
        vault.deposit{value: DEPOSIT_AMOUNT}(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();
    }

    function test_ScheduleUnstake() public {
        // Setup: deposit first
        vm.startPrank(alice);
        vault.deposit{value: DEPOSIT_AMOUNT}(DEPOSIT_AMOUNT, alice);
        
        vm.expectEmit(true, true, true, true);
        emit UnstakeScheduled(alice, DEPOSIT_AMOUNT, block.timestamp);
        vault.scheduleUnstake(DEPOSIT_AMOUNT);
        
        (uint256 amount, uint256 timestamp, TangleByzantineVault.UnstakeState state) = vault.unstakeRequests(alice);
        assertEq(amount, DEPOSIT_AMOUNT);
        assertEq(uint256(state), uint256(TangleByzantineVault.UnstakeState.Scheduled));
        vm.stopPrank();
    }

    function test_CancelUnstake() public {
        // Setup: deposit and schedule unstake
        vm.startPrank(alice);
        vault.deposit{value: DEPOSIT_AMOUNT}(DEPOSIT_AMOUNT, alice);
        vault.scheduleUnstake(DEPOSIT_AMOUNT);
        
        vm.expectEmit(true, true, true, true);
        emit UnstakeCancelled(alice, DEPOSIT_AMOUNT);
        vault.cancelUnstake();
        
        (uint256 amount, uint256 timestamp, TangleByzantineVault.UnstakeState state) = vault.unstakeRequests(alice);
        assertEq(amount, 0);
        assertEq(uint256(state), uint256(TangleByzantineVault.UnstakeState.None));
        vm.stopPrank();
    }

    function test_ScheduleWithdraw() public {
        // Setup: deposit and schedule unstake
        vm.startPrank(alice);
        vault.deposit{value: DEPOSIT_AMOUNT}(DEPOSIT_AMOUNT, alice);
        vault.scheduleUnstake(DEPOSIT_AMOUNT);
        
        // Set unstake state to executed (would normally happen through executeDelegatorUnstake)
        vm.store(
            address(vault),
            keccak256(abi.encode(alice, uint256(3))), // slot for unstakeRequests
            bytes32(uint256(2)) // Executed state
        );
        
        vm.expectEmit(true, true, true, true);
        emit WithdrawScheduled(alice, DEPOSIT_AMOUNT, block.timestamp);
        vault.scheduleWithdraw(DEPOSIT_AMOUNT);
        
        (uint256 amount, uint256 timestamp, TangleByzantineVault.WithdrawState state) = vault.withdrawRequests(alice);
        assertEq(amount, DEPOSIT_AMOUNT);
        assertEq(uint256(state), uint256(TangleByzantineVault.WithdrawState.Scheduled));
        vm.stopPrank();
    }

    function test_CancelWithdrawAndRedelegate() public {
        // Setup: deposit, schedule unstake, and schedule withdraw
        vm.startPrank(alice);
        vault.deposit{value: DEPOSIT_AMOUNT}(DEPOSIT_AMOUNT, alice);
        vault.scheduleUnstake(DEPOSIT_AMOUNT);
        
        // Set unstake state to executed
        vm.store(
            address(vault),
            keccak256(abi.encode(alice, uint256(3))),
            bytes32(uint256(2))
        );
        
        vault.scheduleWithdraw(DEPOSIT_AMOUNT);
        
        vm.expectEmit(true, true, true, true);
        emit WithdrawCancelled(alice, DEPOSIT_AMOUNT);
        vm.expectEmit(true, true, true, true);
        emit AssetsDelegated(alice, DEPOSIT_AMOUNT);
        vault.cancelWithdrawAndRedelegate();
        
        (uint256 amount, uint256 timestamp, TangleByzantineVault.WithdrawState state) = vault.withdrawRequests(alice);
        assertEq(amount, 0);
        assertEq(uint256(state), uint256(TangleByzantineVault.WithdrawState.None));
        vm.stopPrank();
    }

    function test_Withdraw() public {
        // Setup: complete deposit and withdrawal scheduling
        vm.startPrank(alice);
        vault.deposit{value: DEPOSIT_AMOUNT}(DEPOSIT_AMOUNT, alice);
        vault.scheduleUnstake(DEPOSIT_AMOUNT);
        
        // Set unstake state to executed
        vm.store(
            address(vault),
            keccak256(abi.encode(alice, uint256(3))),
            bytes32(uint256(2))
        );
        
        vault.scheduleWithdraw(DEPOSIT_AMOUNT);
        
        uint256 balanceBefore = alice.balance;
        vault.withdraw(DEPOSIT_AMOUNT, alice, alice);
        assertEq(alice.balance - balanceBefore, DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    function testFuzz_PartialWithdraw(uint256 withdrawAmount) public {
        vm.assume(withdrawAmount > 0 && withdrawAmount < DEPOSIT_AMOUNT);
        
        // Setup: complete deposit and withdrawal scheduling
        vm.startPrank(alice);
        vault.deposit{value: DEPOSIT_AMOUNT}(DEPOSIT_AMOUNT, alice);
        vault.scheduleUnstake(DEPOSIT_AMOUNT);
        
        // Set unstake state to executed
        vm.store(
            address(vault),
            keccak256(abi.encode(alice, uint256(3))),
            bytes32(uint256(2))
        );
        
        vault.scheduleWithdraw(DEPOSIT_AMOUNT);
        
        uint256 balanceBefore = alice.balance;
        vault.withdraw(withdrawAmount, alice, alice);
        assertEq(alice.balance - balanceBefore, withdrawAmount);
        
        (uint256 amount, uint256 timestamp, TangleByzantineVault.WithdrawState state) = vault.withdrawRequests(alice);
        assertEq(amount, DEPOSIT_AMOUNT - withdrawAmount);
        vm.stopPrank();
    }

    // Error cases
    function test_RevertWhen_UnstakeWithoutBalance() public {
        vm.startPrank(alice);
        vm.expectRevert(TangleByzantineVault.UnstakeAmountExceedsBalance.selector);
        vault.scheduleUnstake(DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    function test_RevertWhen_WithdrawWithoutUnstake() public {
        vm.startPrank(alice);
        vault.deposit{value: DEPOSIT_AMOUNT}(DEPOSIT_AMOUNT, alice);
        vm.expectRevert(TangleByzantineVault.InvalidState.selector);
        vault.scheduleWithdraw(DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    function test_RevertWhen_CancelNonexistentUnstake() public {
        vm.startPrank(alice);
        vm.expectRevert(TangleByzantineVault.NoUnstakeToCancel.selector);
        vault.cancelUnstake();
        vm.stopPrank();
    }

    function test_RevertWhen_CancelNonexistentWithdraw() public {
        vm.startPrank(alice);
        vm.expectRevert(TangleByzantineVault.NoWithdrawToCancel.selector);
        vault.cancelWithdrawAndRedelegate();
        vm.stopPrank();
    }

    function test_UserIsolation_UnstakeRequests() public {
        // Setup: Both users deposit
        vm.startPrank(alice);
        vault.deposit{value: DEPOSIT_AMOUNT}(DEPOSIT_AMOUNT, alice);
        vault.scheduleUnstake(DEPOSIT_AMOUNT);
        vm.stopPrank();

        vm.startPrank(bob);
        vault.deposit{value: DEPOSIT_AMOUNT}(DEPOSIT_AMOUNT, bob);
        
        // Verify bob can't cancel alice's unstake
        vm.expectRevert(TangleByzantineVault.NoUnstakeToCancel.selector);
        vault.cancelUnstake();
        
        // Verify alice's unstake request remains unchanged
        (uint256 amount, uint256 timestamp, TangleByzantineVault.UnstakeState state) = vault.unstakeRequests(alice);
        assertEq(amount, DEPOSIT_AMOUNT);
        assertEq(uint256(state), uint256(TangleByzantineVault.UnstakeState.Scheduled));
        vm.stopPrank();
    }

    function test_UserIsolation_WithdrawRequests() public {
        // Setup: Both users deposit and schedule unstakes
        vm.startPrank(alice);
        vault.deposit{value: DEPOSIT_AMOUNT}(DEPOSIT_AMOUNT, alice);
        vault.scheduleUnstake(DEPOSIT_AMOUNT);
        vm.store(
            address(vault),
            keccak256(abi.encode(alice, uint256(3))),
            bytes32(uint256(2)) // Set to Executed state
        );
        vault.scheduleWithdraw(DEPOSIT_AMOUNT);
        vm.stopPrank();

        vm.startPrank(bob);
        vault.deposit{value: DEPOSIT_AMOUNT}(DEPOSIT_AMOUNT, bob);
        vault.scheduleUnstake(DEPOSIT_AMOUNT);
        
        // Verify bob can't cancel alice's withdrawal
        vm.expectRevert(TangleByzantineVault.NoWithdrawToCancel.selector);
        vault.cancelWithdrawAndRedelegate();
        
        // Verify alice's withdrawal request remains unchanged
        (uint256 amount, uint256 timestamp, TangleByzantineVault.WithdrawState state) = vault.withdrawRequests(alice);
        assertEq(amount, DEPOSIT_AMOUNT);
        assertEq(uint256(state), uint256(TangleByzantineVault.WithdrawState.Scheduled));
        vm.stopPrank();
    }

    function test_UserIsolation_WithdrawExecution() public {
        // Setup: Both users deposit and schedule withdrawals
        vm.startPrank(alice);
        vault.deposit{value: DEPOSIT_AMOUNT}(DEPOSIT_AMOUNT, alice);
        vault.scheduleUnstake(DEPOSIT_AMOUNT);
        vm.store(
            address(vault),
            keccak256(abi.encode(alice, uint256(3))),
            bytes32(uint256(2))
        );
        vault.scheduleWithdraw(DEPOSIT_AMOUNT);
        vm.stopPrank();

        vm.startPrank(bob);
        vault.deposit{value: DEPOSIT_AMOUNT}(DEPOSIT_AMOUNT, bob);
        
        // Verify bob can't withdraw using alice's scheduled withdrawal
        vm.expectRevert(); // Should revert when trying to withdraw without scheduling
        vault.withdraw(DEPOSIT_AMOUNT, bob, alice);
        
        // Verify alice can still withdraw her funds
        vm.stopPrank();
        vm.startPrank(alice);
        uint256 balanceBefore = alice.balance;
        vault.withdraw(DEPOSIT_AMOUNT, alice, alice);
        assertEq(alice.balance - balanceBefore, DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    function test_UserIsolation_ConcurrentWithdrawals() public {
        // Setup: Both users deposit same amounts
        vm.startPrank(alice);
        vault.deposit{value: DEPOSIT_AMOUNT}(DEPOSIT_AMOUNT, alice);
        vault.scheduleUnstake(DEPOSIT_AMOUNT);
        vm.store(
            address(vault),
            keccak256(abi.encode(alice, uint256(3))),
            bytes32(uint256(2))
        );
        vault.scheduleWithdraw(DEPOSIT_AMOUNT);
        vm.stopPrank();

        vm.startPrank(bob);
        vault.deposit{value: DEPOSIT_AMOUNT}(DEPOSIT_AMOUNT, bob);
        vault.scheduleUnstake(DEPOSIT_AMOUNT);
        vm.store(
            address(vault),
            keccak256(abi.encode(bob, uint256(3))),
            bytes32(uint256(2))
        );
        vault.scheduleWithdraw(DEPOSIT_AMOUNT);
        vm.stopPrank();

        // Execute withdrawals for both users
        vm.prank(alice);
        vault.withdraw(DEPOSIT_AMOUNT, alice, alice);
        
        vm.prank(bob);
        vault.withdraw(DEPOSIT_AMOUNT, bob, bob);

        // Verify both users got their correct amounts
        assertEq(alice.balance, 100 ether); // Initial balance restored
        assertEq(bob.balance, 100 ether); // Initial balance restored
    }

    function test_UserIsolation_PartialWithdrawals() public {
        uint256 partialAmount = DEPOSIT_AMOUNT / 2;

        // Setup: Both users deposit and schedule withdrawals
        vm.startPrank(alice);
        vault.deposit{value: DEPOSIT_AMOUNT}(DEPOSIT_AMOUNT, alice);
        vault.scheduleUnstake(DEPOSIT_AMOUNT);
        vm.store(
            address(vault),
            keccak256(abi.encode(alice, uint256(3))),
            bytes32(uint256(2))
        );
        vault.scheduleWithdraw(DEPOSIT_AMOUNT);
        vm.stopPrank();

        vm.startPrank(bob);
        vault.deposit{value: DEPOSIT_AMOUNT}(DEPOSIT_AMOUNT, bob);
        vault.scheduleUnstake(DEPOSIT_AMOUNT);
        vm.store(
            address(vault),
            keccak256(abi.encode(bob, uint256(3))),
            bytes32(uint256(2))
        );
        vault.scheduleWithdraw(DEPOSIT_AMOUNT);
        vm.stopPrank();

        // Alice performs partial withdrawal
        vm.prank(alice);
        vault.withdraw(partialAmount, alice, alice);

        // Verify bob's full withdrawal amount is still available
        (uint256 bobAmount, uint256 bobTimestamp, TangleByzantineVault.WithdrawState bobState) = vault.withdrawRequests(bob);
        assertEq(bobAmount, DEPOSIT_AMOUNT);

        // Verify alice's remaining withdrawal amount
        (uint256 aliceAmount, uint256 aliceTimestamp, TangleByzantineVault.WithdrawState aliceState) = vault.withdrawRequests(alice);
        assertEq(aliceAmount, partialAmount);
    }

    receive() external payable {}
}
