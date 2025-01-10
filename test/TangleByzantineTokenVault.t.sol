// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {TangleByzantineTokenVault} from "../src/TangleByzantineTokenVault.sol";
import {MultiAssetDelegation, MULTI_ASSET_DELEGATION_CONTRACT} from "../src/MultiAssetDelegation.sol";
import {IOracle} from "dependencies/byzantine-contracts/src/interfaces/IOracle.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock Token", "MTK") {
        _mint(msg.sender, 1000000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

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

    // Implement remaining interface functions
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

contract TangleByzantineTokenVaultTest is Test {
    TangleByzantineTokenVault public vault;
    MockOracle public oracle;
    MockMultiAssetDelegation public mockDelegation;
    MockToken public token;
    
    bytes32 public constant OPERATOR = bytes32(uint256(1));
    uint64[] public blueprintSelection;
    address public alice = address(0x1);
    address public bob = address(0x2);
    uint256 public constant DEPOSIT_AMOUNT = 1000 ether;

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
        token = new MockToken();
        
        // Setup blueprint selection
        blueprintSelection.push(1);
        
        // Deploy vault with mocks
        vm.etch(address(0x822), address(mockDelegation).code);
        vault = new TangleByzantineTokenVault();
        vault.initialize(address(oracle), address(token), OPERATOR, blueprintSelection);

        // Fund test accounts
        token.mint(alice, 100_000 ether);
        token.mint(bob, 100_000 ether);

        vm.startPrank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        token.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function test_Initialize() public {
        assertEq(vault.operator(), OPERATOR);
        assertEq(vault.blueprintSelection(0), blueprintSelection[0]);
        assertEq(token.allowance(address(vault), address(MULTI_ASSET_DELEGATION_CONTRACT)), type(uint256).max);
    }

    function testFuzz_Initialize_InvalidOperator(bytes32 invalidOperator) public {
        vm.assume(invalidOperator == bytes32(0));
        
        vault = new TangleByzantineTokenVault();
        vm.expectRevert(TangleByzantineTokenVault.InvalidOperator.selector);
        vault.initialize(address(oracle), address(token), invalidOperator, blueprintSelection);
    }

    function test_Deposit() public {
        vm.startPrank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        assertEq(token.balanceOf(address(vault)), DEPOSIT_AMOUNT);
        assertEq(vault.balanceOf(alice), DEPOSIT_AMOUNT);
    }

    function test_DepositFailsOnDelegation() public {
        MockMultiAssetDelegation(address(0x822)).setShouldRevert(true);
        
        vm.startPrank(alice);
        vm.expectRevert(TangleByzantineTokenVault.DelegationFailed.selector);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();
    }

    function test_ScheduleUnstake() public {
        // Setup: deposit first
        vm.startPrank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        
        vm.expectEmit(true, true, true, true);
        emit UnstakeScheduled(alice, DEPOSIT_AMOUNT, block.timestamp);
        vault.scheduleUnstake(DEPOSIT_AMOUNT);
        
        (uint256 amount, uint256 timestamp, TangleByzantineTokenVault.UnstakeState state) = vault.getUnstakeRequest(alice);
        assertEq(amount, DEPOSIT_AMOUNT);
        assertEq(uint256(state), uint256(TangleByzantineTokenVault.UnstakeState.Scheduled));
        vm.stopPrank();
    }

    function test_CancelUnstake() public {
        // Setup: deposit and schedule unstake
        vm.startPrank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vault.scheduleUnstake(DEPOSIT_AMOUNT);
        
        vm.expectEmit(true, true, true, true);
        emit UnstakeCancelled(alice, DEPOSIT_AMOUNT);
        vault.cancelUnstake();
        
        (uint256 amount,,) = vault.getUnstakeRequest(alice);
        assertEq(amount, 0);
        vm.stopPrank();
    }

    function test_ScheduleWithdraw() public {
        // Setup: complete deposit and unstaking
        vm.startPrank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vault.scheduleUnstake(DEPOSIT_AMOUNT);
        
        // Set unstake state to executed
        vm.store(
            address(vault),
            keccak256(abi.encode(alice, uint256(3))),
            bytes32(uint256(2))
        );
        
        vm.expectEmit(true, true, true, true);
        emit WithdrawScheduled(alice, DEPOSIT_AMOUNT, block.timestamp);
        vault.scheduleWithdraw(DEPOSIT_AMOUNT);
        
        (uint256 amount, uint256 timestamp, TangleByzantineTokenVault.WithdrawState state) = vault.getWithdrawRequest(alice);
        assertEq(amount, DEPOSIT_AMOUNT);
        assertEq(uint256(state), uint256(TangleByzantineTokenVault.WithdrawState.Scheduled));
        vm.stopPrank();
    }

    function test_CancelWithdrawAndRedelegate() public {
        // Setup: complete deposit, unstaking, and withdrawal scheduling
        vm.startPrank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);
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
        
        (uint256 amount,,) = vault.getWithdrawRequest(alice);
        assertEq(amount, 0);
        vm.stopPrank();
    }

    function test_UserIsolation_UnstakeRequests() public {
        // Setup: Both users deposit
        vm.startPrank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vault.scheduleUnstake(DEPOSIT_AMOUNT);
        vm.stopPrank();

        vm.startPrank(bob);
        vault.deposit(DEPOSIT_AMOUNT, bob);
        
        // Verify bob can't cancel alice's unstake
        vm.expectRevert(TangleByzantineTokenVault.NoUnstakeToCancel.selector);
        vault.cancelUnstake();
        
        // Verify alice's unstake request remains unchanged
        (uint256 amount,, TangleByzantineTokenVault.UnstakeState state) = vault.getUnstakeRequest(alice);
        assertEq(amount, DEPOSIT_AMOUNT);
        assertEq(uint256(state), uint256(TangleByzantineTokenVault.UnstakeState.Scheduled));
        vm.stopPrank();
    }

    function test_UserIsolation_WithdrawRequests() public {
        // Setup: Both users deposit and schedule unstakes
        vm.startPrank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vault.scheduleUnstake(DEPOSIT_AMOUNT);
        vm.store(
            address(vault),
            keccak256(abi.encode(alice, uint256(3))),
            bytes32(uint256(2))
        );
        vault.scheduleWithdraw(DEPOSIT_AMOUNT);
        vm.stopPrank();

        vm.startPrank(bob);
        vault.deposit(DEPOSIT_AMOUNT, bob);
        vault.scheduleUnstake(DEPOSIT_AMOUNT);
        
        // Verify bob can't cancel alice's withdrawal
        vm.expectRevert(TangleByzantineTokenVault.NoWithdrawToCancel.selector);
        vault.cancelWithdrawAndRedelegate();
        
        // Verify alice's withdrawal request remains unchanged
        (uint256 amount,, TangleByzantineTokenVault.WithdrawState state) = vault.getWithdrawRequest(alice);
        assertEq(amount, DEPOSIT_AMOUNT);
        assertEq(uint256(state), uint256(TangleByzantineTokenVault.WithdrawState.Scheduled));
        vm.stopPrank();
    }

    function test_UserIsolation_PartialWithdrawals() public {
        uint256 partialAmount = DEPOSIT_AMOUNT / 2;

        // Setup: Both users deposit and schedule withdrawals
        vm.startPrank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vault.scheduleUnstake(DEPOSIT_AMOUNT);
        vm.store(
            address(vault),
            keccak256(abi.encode(alice, uint256(3))),
            bytes32(uint256(2))
        );
        vault.scheduleWithdraw(DEPOSIT_AMOUNT);
        vm.stopPrank();

        vm.startPrank(bob);
        vault.deposit(DEPOSIT_AMOUNT, bob);
        vault.scheduleUnstake(DEPOSIT_AMOUNT);
        vm.store(
            address(vault),
            keccak256(abi.encode(bob, uint256(3))),
            bytes32(uint256(2))
        );
        vault.scheduleWithdraw(DEPOSIT_AMOUNT);
        vm.stopPrank();

        // Alice performs partial withdrawal
        vm.startPrank(alice);
        vault.withdraw(partialAmount, alice, alice);
        vm.stopPrank();

        // Verify bob's full withdrawal amount is still available
        (uint256 bobAmount,, TangleByzantineTokenVault.WithdrawState bobState) = vault.getWithdrawRequest(bob);
        assertEq(bobAmount, DEPOSIT_AMOUNT);

        // Verify alice's remaining withdrawal amount
        (uint256 aliceAmount,, TangleByzantineTokenVault.WithdrawState aliceState) = vault.getWithdrawRequest(alice);
        assertEq(aliceAmount, partialAmount);
    }

    // Error cases
    function test_RevertWhen_UnstakeWithoutBalance() public {
        vm.startPrank(alice);
        vm.expectRevert(TangleByzantineTokenVault.UnstakeAmountExceedsBalance.selector);
        vault.scheduleUnstake(DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    function test_RevertWhen_WithdrawWithoutUnstake() public {
        vm.startPrank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.expectRevert(TangleByzantineTokenVault.InvalidState.selector);
        vault.scheduleWithdraw(DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    function test_RevertWhen_CancelNonexistentUnstake() public {
        vm.startPrank(alice);
        vm.expectRevert(TangleByzantineTokenVault.NoUnstakeToCancel.selector);
        vault.cancelUnstake();
        vm.stopPrank();
    }

    function test_RevertWhen_CancelNonexistentWithdraw() public {
        vm.startPrank(alice);
        vm.expectRevert(TangleByzantineTokenVault.NoWithdrawToCancel.selector);
        vault.cancelWithdrawAndRedelegate();
        vm.stopPrank();
    }
} 