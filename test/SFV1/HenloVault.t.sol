// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HenloVault} from "../../src/SFV1/vaults/HenloVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";

/**
 * @title HenloVaultTest
 * @notice Test suite for HenloVault functionality
 */
contract HenloVaultTest is Test {
    HenloVault public vault;
    HenloVault public vaultImpl;
    MockERC20 public henloToken;
    MockStrategy public strategy;
    
    address public admin = makeAddr("admin");
    address public strategist = makeAddr("strategist");
    address public keeper = makeAddr("keeper");
    address public feeRecipient = makeAddr("feeRecipient");
    address public user = makeAddr("user");
    
    uint256 public constant INITIAL_BALANCE = 1000e18;
    uint256 public constant DEFAULT_DEPOSIT_LIMIT = 1_000_000e18;

    function setUp() public {
        // Deploy HENLO token
        henloToken = new MockERC20("HENLO Token", "HENLO", 18);
        
        // Deploy vault implementation
        vaultImpl = new HenloVault();
        
        // Deploy vault proxy
        bytes memory initData = abi.encodeWithSelector(
            HenloVault.initialize.selector,
            henloToken,
            admin,
            strategist,
            keeper,
            feeRecipient
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(address(vaultImpl), initData);
        vault = HenloVault(address(proxy));
        
        // Deploy mock strategy
        strategy = new MockStrategy(address(henloToken), address(vault));
        
        // Setup initial balances
        henloToken.mint(user, INITIAL_BALANCE);
        henloToken.mint(address(strategy), 100e18);
        
        // User approves vault
        vm.prank(user);
        henloToken.approve(address(vault), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testInitialization() public {
        assertEq(address(vault.asset()), address(henloToken));
        assertEq(vault.name(), "Set & Forgetti HENLO Vault");
        assertEq(vault.symbol(), "sfHENLO");
        assertEq(vault.depositLimit(), DEFAULT_DEPOSIT_LIMIT);
        assertEq(vault.performanceFee(), 2000); // 20%
        assertEq(vault.managementFee(), 200); // 2%
        assertEq(vault.feeRecipient(), feeRecipient);
        assertEq(vault.minimumTotalIdle(), 500); // 5%
    }

    /*//////////////////////////////////////////////////////////////
                            DEPOSIT LIMIT TESTS
    //////////////////////////////////////////////////////////////*/

    function testDepositLimit() public {
        uint256 maxDeposit = vault.maxDeposit(user);
        assertEq(maxDeposit, DEFAULT_DEPOSIT_LIMIT);
        
        // Deposit up to limit
        vm.prank(user);
        vault.deposit(100e18, user);
        
        maxDeposit = vault.maxDeposit(user);
        assertEq(maxDeposit, DEFAULT_DEPOSIT_LIMIT - 100e18);
    }

    function testDepositLimitExceeded() public {
        // Set a small deposit limit for testing
        vm.prank(admin);
        vault.setDepositLimit(50e18);
        
        vm.prank(user);
        vm.expectRevert(HenloVault.DepositLimitExceeded.selector);
        vault.deposit(100e18, user);
    }

    function testMaxDepositWhenPaused() public {
        vm.prank(admin);
        vault.pause();
        
        assertEq(vault.maxDeposit(user), 0);
    }

    /*//////////////////////////////////////////////////////////////
                            FEE TESTS
    //////////////////////////////////////////////////////////////*/

    function testManagementFeeCollection() public {
        // Deposit some assets
        vm.prank(user);
        vault.deposit(100e18, user);
        
        uint256 totalSharesBefore = vault.totalSupply();
        uint256 feeRecipientSharesBefore = vault.balanceOf(feeRecipient);
        
        // Fast forward 1 year
        vm.warp(block.timestamp + 365 days);
        
        // Collect management fees
        vm.prank(keeper);
        vault.collectManagementFees();
        
        uint256 totalSharesAfter = vault.totalSupply();
        uint256 feeRecipientSharesAfter = vault.balanceOf(feeRecipient);
        
        // Fee recipient should have received shares
        assertGt(feeRecipientSharesAfter, feeRecipientSharesBefore);
        assertGt(totalSharesAfter, totalSharesBefore);
        
        // Should be approximately 2% of total shares
        uint256 feeShares = feeRecipientSharesAfter - feeRecipientSharesBefore;
        uint256 expectedFees = (totalSharesBefore * 200) / 10000; // 2%
        assertApproxEqual(feeShares, expectedFees, expectedFees / 10); // 10% tolerance
    }

    function testPerformanceFeeCollection() public {
        // Deposit and allocate to strategy
        vm.prank(user);
        vault.deposit(100e18, user);
        
        vm.prank(strategist);
        vault.addStrategy(address(strategy), 50e18);
        
        vm.prank(strategist);
        vault.updateDebt(address(strategy), 50e18);
        
        // Generate profit in strategy
        uint256 profit = 10e18;
        strategy.setProfit(profit);
        
        uint256 feeRecipientSharesBefore = vault.balanceOf(feeRecipient);
        
        // Collect performance fees
        vm.prank(keeper);
        uint256 feeShares = vault.collectPerformanceFees(profit);
        
        uint256 feeRecipientSharesAfter = vault.balanceOf(feeRecipient);
        
        // Fee recipient should have received shares
        assertGt(feeShares, 0);
        assertEq(feeRecipientSharesAfter, feeRecipientSharesBefore + feeShares);
        
        // Should be 20% of profit converted to shares
        uint256 expectedFeeAmount = (profit * 2000) / 10000; // 20%
        uint256 expectedFeeShares = vault.convertToShares(expectedFeeAmount);
        assertApproxEqual(feeShares, expectedFeeShares, expectedFeeShares / 10);
    }

    /*//////////////////////////////////////////////////////////////
                            STRATEGY INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testInitializeWithStrategies() public {
        uint256 initialAllocation = 5000; // 50%
        
        vm.prank(strategist);
        vault.initializeWithStrategies(address(strategy), initialAllocation);
        
        // Strategy should be added with correct max debt
        uint256 expectedMaxDebt = (DEFAULT_DEPOSIT_LIMIT * initialAllocation) / 10000;
        (, , , uint256 maxDebt, bool isActive) = vault.strategies(address(strategy));
        
        assertEq(maxDebt, expectedMaxDebt);
        assertEq(isActive, true);
    }

    function testRebalance() public {
        // Setup strategy
        vm.prank(strategist);
        vault.addStrategy(address(strategy), 500e18);
        
        // Deposit assets
        vm.prank(user);
        vault.deposit(100e18, user);
        
        // Allocate to strategy
        vm.prank(strategist);
        vault.updateDebt(address(strategy), 95e18); // Almost all funds
        
        uint256 idleBefore = vault.totalIdle();
        assertLt(idleBefore, (vault.totalAssets() * vault.minimumTotalIdle()) / 10000);
        
        // Rebalance should bring funds back to maintain minimum idle
        vm.prank(keeper);
        vault.rebalance();
        
        uint256 idleAfter = vault.totalIdle();
        uint256 expectedMinIdle = (vault.totalAssets() * vault.minimumTotalIdle()) / 10000;
        assertGe(idleAfter, expectedMinIdle);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testSetDepositLimit() public {
        uint256 newLimit = 500e18;
        
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit HenloVault.DepositLimitUpdated(DEFAULT_DEPOSIT_LIMIT, newLimit);
        
        vault.setDepositLimit(newLimit);
        
        assertEq(vault.depositLimit(), newLimit);
    }

    function testSetPerformanceFee() public {
        uint256 newFee = 1500; // 15%
        
        vm.prank(admin);
        vault.setPerformanceFee(newFee);
        
        assertEq(vault.performanceFee(), newFee);
    }

    function testSetPerformanceFeeExceedsMax() public {
        vm.prank(admin);
        vm.expectRevert(HenloVault.InvalidFee.selector);
        vault.setPerformanceFee(5001); // > 50%
    }

    function testSetManagementFee() public {
        uint256 newFee = 150; // 1.5%
        
        vm.prank(admin);
        vault.setManagementFee(newFee);
        
        assertEq(vault.managementFee(), newFee);
    }

    function testSetFeeRecipient() public {
        address newRecipient = makeAddr("newRecipient");
        
        vm.prank(admin);
        vault.setFeeRecipient(newRecipient);
        
        assertEq(vault.feeRecipient(), newRecipient);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testGetVaultInfo() public {
        vm.prank(user);
        vault.deposit(100e18, user);
        
        (
            uint256 totalAssets_,
            uint256 totalSupply_,
            uint256 totalIdle_,
            uint256 totalDebt_,
            uint256 depositLimit_,
            uint256 performanceFee_,
            uint256 managementFee_
        ) = vault.getVaultInfo();
        
        assertEq(totalAssets_, 100e18);
        assertEq(totalSupply_, 100e18);
        assertEq(totalIdle_, 100e18);
        assertEq(totalDebt_, 0);
        assertEq(depositLimit_, DEFAULT_DEPOSIT_LIMIT);
        assertEq(performanceFee_, 2000);
        assertEq(managementFee_, 200);
    }

    function testPreviewDepositAfterFees() public {
        vm.prank(user);
        vault.deposit(100e18, user);
        
        // Fast forward some time
        vm.warp(block.timestamp + 30 days);
        
        uint256 shares = vault.previewDepositAfterFees(50e18);
        uint256 regularShares = vault.convertToShares(50e18);
        
        // Should receive fewer shares due to management fee dilution
        assertLt(shares, regularShares);
    }

    /*//////////////////////////////////////////////////////////////
                            EMERGENCY TESTS
    //////////////////////////////////////////////////////////////*/

    function testEmergencyWithdrawAll() public {
        // Setup strategy with debt
        vm.prank(strategist);
        vault.addStrategy(address(strategy), 500e18);
        
        vm.prank(user);
        vault.deposit(100e18, user);
        
        vm.prank(strategist);
        vault.updateDebt(address(strategy), 50e18);
        
        uint256 debtBefore = vault.totalDebt();
        assertGt(debtBefore, 0);
        
        // Emergency withdraw
        vm.prank(admin);
        vault.emergencyWithdrawAll();
        
        uint256 debtAfter = vault.totalDebt();
        assertEq(debtAfter, 0);
        
        (, , uint256 currentDebt, ,) = vault.strategies(address(strategy));
        assertEq(currentDebt, 0);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function assertApproxEqual(uint256 a, uint256 b, uint256 tolerance) internal {
        uint256 diff = a > b ? a - b : b - a;
        assertLe(diff, tolerance, "Values not approximately equal");
    }
}