// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseVault} from "../../src/SFV1/BaseVault.sol";
import {IStrategy} from "../../src/SFV1/interfaces/IStrategy.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";

/**
 * @title BaseVaultTest
 * @notice Test suite for BaseVault functionality
 */
contract BaseVaultTest is Test {
    BaseVault public vault;
    BaseVault public vaultImpl;
    MockERC20 public asset;
    MockStrategy public strategy;
    
    address public admin = makeAddr("admin");
    address public strategist = makeAddr("strategist");
    address public keeper = makeAddr("keeper");
    address public user = makeAddr("user");
    
    uint256 public constant INITIAL_BALANCE = 1000e18;
    uint256 public constant STRATEGY_MAX_DEBT = 500e18;

    event StrategyAdded(address indexed strategy, uint256 maxDebt);
    event DebtUpdated(address indexed strategy, uint256 currentDebt, uint256 newDebt);
    event StrategyReported(
        address indexed strategy,
        uint256 gain,
        uint256 loss,
        uint256 currentDebt,
        uint256 totalFees
    );

    function setUp() public {
        // Deploy mock asset token
        asset = new MockERC20("Test Asset", "TST", 18);
        
        // Deploy vault implementation
        vaultImpl = new BaseVault();
        
        // Deploy vault proxy
        bytes memory initData = abi.encodeWithSelector(
            BaseVault.initialize.selector,
            asset,
            "Test Vault",
            "tVAULT",
            admin,
            strategist,
            keeper
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(address(vaultImpl), initData);
        vault = BaseVault(address(proxy));
        
        // Deploy mock strategy
        strategy = new MockStrategy(address(asset), address(vault));
        
        // Setup initial balances
        asset.mint(user, INITIAL_BALANCE);
        asset.mint(address(strategy), 100e18); // Strategy has some assets
        
        // User approves vault
        vm.prank(user);
        asset.approve(address(vault), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testInitialization() public {
        assertEq(address(vault.asset()), address(asset));
        assertEq(vault.name(), "Test Vault");
        assertEq(vault.symbol(), "tVAULT");
        assertEq(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin), true);
        assertEq(vault.hasRole(vault.STRATEGIST_ROLE(), strategist), true);
        assertEq(vault.hasRole(vault.KEEPER_ROLE(), keeper), true);
        assertEq(vault.minimumTotalIdle(), 100); // 1% default
        assertEq(vault.maxLoss(), 100); // 1% default
    }

    /*//////////////////////////////////////////////////////////////
                            STRATEGY MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function testAddStrategy() public {
        vm.prank(strategist);
        vm.expectEmit(true, false, false, true);
        emit StrategyAdded(address(strategy), STRATEGY_MAX_DEBT);
        
        vault.addStrategy(address(strategy), STRATEGY_MAX_DEBT);
        
        (uint256 activation, , uint256 currentDebt, uint256 maxDebt, bool isActive) = 
            vault.strategies(address(strategy));
        
        assertEq(activation, block.timestamp);
        assertEq(currentDebt, 0);
        assertEq(maxDebt, STRATEGY_MAX_DEBT);
        assertEq(isActive, true);
        
        address[] memory queue = vault.getStrategyQueue();
        assertEq(queue.length, 1);
        assertEq(queue[0], address(strategy));
    }

    function testAddStrategyOnlyStrategist() public {
        vm.prank(user);
        vm.expectRevert();
        vault.addStrategy(address(strategy), STRATEGY_MAX_DEBT);
    }

    function testAddStrategyZeroAddress() public {
        vm.prank(strategist);
        vm.expectRevert(BaseVault.ZeroAddress.selector);
        vault.addStrategy(address(0), STRATEGY_MAX_DEBT);
    }

    function testUpdateDebt() public {
        // First add strategy
        vm.prank(strategist);
        vault.addStrategy(address(strategy), STRATEGY_MAX_DEBT);
        
        // Deposit some assets to vault
        vm.prank(user);
        vault.deposit(100e18, user);
        
        // Update debt allocation
        uint256 targetDebt = 50e18;
        vm.prank(strategist);
        vm.expectEmit(true, false, false, true);
        emit DebtUpdated(address(strategy), 0, targetDebt);
        
        uint256 actualDebt = vault.updateDebt(address(strategy), targetDebt);
        
        assertEq(actualDebt, targetDebt);
        assertEq(vault.totalDebt(), targetDebt);
        
        (, , uint256 currentDebt, ,) = vault.strategies(address(strategy));
        assertEq(currentDebt, targetDebt);
    }

    function testUpdateDebtExceedsMax() public {
        vm.prank(strategist);
        vault.addStrategy(address(strategy), STRATEGY_MAX_DEBT);
        
        vm.prank(user);
        vault.deposit(100e18, user);
        
        vm.prank(strategist);
        vm.expectRevert(BaseVault.DebtExceedsMax.selector);
        vault.updateDebt(address(strategy), STRATEGY_MAX_DEBT + 1);
    }

    function testRevokeStrategy() public {
        // Add strategy with some debt
        vm.prank(strategist);
        vault.addStrategy(address(strategy), STRATEGY_MAX_DEBT);
        
        vm.prank(user);
        vault.deposit(100e18, user);
        
        vm.prank(strategist);
        vault.updateDebt(address(strategy), 50e18);
        
        // Revoke strategy
        vm.prank(strategist);
        vault.revokeStrategy(address(strategy));
        
        (, , uint256 currentDebt, , bool isActive) = vault.strategies(address(strategy));
        assertEq(currentDebt, 0);
        assertEq(isActive, false);
        
        // Strategy should be removed from queue
        address[] memory queue = vault.getStrategyQueue();
        assertEq(queue.length, 0);
    }

    /*//////////////////////////////////////////////////////////////
                            DEPOSIT/WITHDRAW TESTS
    //////////////////////////////////////////////////////////////*/

    function testDeposit() public {
        uint256 depositAmount = 100e18;
        
        vm.prank(user);
        uint256 shares = vault.deposit(depositAmount, user);
        
        assertEq(shares, depositAmount); // 1:1 ratio initially
        assertEq(vault.balanceOf(user), shares);
        assertEq(vault.totalAssets(), depositAmount);
        assertEq(vault.totalIdle(), depositAmount);
        assertEq(asset.balanceOf(address(vault)), depositAmount);
    }

    function testMint() public {
        uint256 shareAmount = 100e18;
        
        vm.prank(user);
        uint256 assets = vault.mint(shareAmount, user);
        
        assertEq(assets, shareAmount); // 1:1 ratio initially
        assertEq(vault.balanceOf(user), shareAmount);
        assertEq(vault.totalAssets(), shareAmount);
        assertEq(asset.balanceOf(address(vault)), shareAmount);
    }

    function testWithdraw() public {
        // First deposit
        vm.prank(user);
        vault.deposit(100e18, user);
        
        // Then withdraw
        uint256 withdrawAmount = 50e18;
        uint256 balanceBefore = asset.balanceOf(user);
        
        vm.prank(user);
        uint256 shares = vault.withdraw(withdrawAmount, user, user);
        
        assertEq(shares, withdrawAmount); // 1:1 ratio
        assertEq(asset.balanceOf(user), balanceBefore + withdrawAmount);
        assertEq(vault.balanceOf(user), 50e18); // Remaining shares
        assertEq(vault.totalAssets(), 50e18);
    }

    function testRedeem() public {
        // First deposit
        vm.prank(user);
        vault.deposit(100e18, user);
        
        // Then redeem
        uint256 redeemShares = 50e18;
        uint256 balanceBefore = asset.balanceOf(user);
        
        vm.prank(user);
        uint256 assets = vault.redeem(redeemShares, user, user);
        
        assertEq(assets, redeemShares); // 1:1 ratio
        assertEq(asset.balanceOf(user), balanceBefore + redeemShares);
        assertEq(vault.balanceOf(user), 50e18); // Remaining shares
    }

    /*//////////////////////////////////////////////////////////////
                            HARVEST TESTS
    //////////////////////////////////////////////////////////////*/

    function testHarvest() public {
        // Setup strategy with debt
        vm.prank(strategist);
        vault.addStrategy(address(strategy), STRATEGY_MAX_DEBT);
        
        vm.prank(user);
        vault.deposit(100e18, user);
        
        vm.prank(strategist);
        vault.updateDebt(address(strategy), 50e18);
        
        // Mock strategy profit
        strategy.setProfit(10e18);
        
        // Harvest
        vm.prank(keeper);
        vault.harvest(address(strategy));
        
        // Check that profit was reported
        assertEq(vault.totalDebt(), 60e18); // Original debt + profit
    }

    function testHarvestOnlyKeeper() public {
        vm.prank(strategist);
        vault.addStrategy(address(strategy), STRATEGY_MAX_DEBT);
        
        vm.prank(user);
        vm.expectRevert();
        vault.harvest(address(strategy));
    }

    /*//////////////////////////////////////////////////////////////
                            ACCESS CONTROL TESTS
    //////////////////////////////////////////////////////////////*/

    function testPauseUnpause() public {
        vm.prank(admin);
        vault.pause();
        assertEq(vault.paused(), true);
        
        // Deposits should fail when paused
        vm.prank(user);
        vm.expectRevert();
        vault.deposit(100e18, user);
        
        vm.prank(admin);
        vault.unpause();
        assertEq(vault.paused(), false);
        
        // Deposits should work again
        vm.prank(user);
        vault.deposit(100e18, user);
    }

    function testSetMinimumTotalIdle() public {
        uint256 newMinimum = 200; // 2%
        
        vm.prank(admin);
        vault.setMinimumTotalIdle(newMinimum);
        
        assertEq(vault.minimumTotalIdle(), newMinimum);
    }

    function testSetMaxLoss() public {
        uint256 newMaxLoss = 200; // 2%
        
        vm.prank(admin);
        vault.setMaxLoss(newMaxLoss);
        
        assertEq(vault.maxLoss(), newMaxLoss);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testTotalAssets() public {
        // Initially empty
        assertEq(vault.totalAssets(), 0);
        
        // After deposit
        vm.prank(user);
        vault.deposit(100e18, user);
        assertEq(vault.totalAssets(), 100e18);
        
        // After allocating to strategy
        vm.prank(strategist);
        vault.addStrategy(address(strategy), STRATEGY_MAX_DEBT);
        
        vm.prank(strategist);
        vault.updateDebt(address(strategy), 50e18);
        
        assertEq(vault.totalAssets(), 100e18); // Total unchanged
        assertEq(vault.totalIdle(), 50e18); // Idle reduced
        assertEq(vault.totalDebt(), 50e18); // Debt increased
    }

    function testConvertToShares() public {
        // 1:1 ratio initially
        assertEq(vault.convertToShares(100e18), 100e18);
        
        // After some profit
        vm.prank(user);
        vault.deposit(100e18, user);
        
        vm.prank(strategist);
        vault.addStrategy(address(strategy), STRATEGY_MAX_DEBT);
        
        vm.prank(strategist);
        vault.updateDebt(address(strategy), 50e18);
        
        // Mock 10% profit
        strategy.setProfit(5e18);
        vm.prank(keeper);
        vault.harvest(address(strategy));
        
        // Now 100e18 assets should give less than 100e18 shares due to profit
        uint256 shares = vault.convertToShares(100e18);
        assertLt(shares, 100e18);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function assertApproxEqual(uint256 a, uint256 b, uint256 tolerance) internal {
        uint256 diff = a > b ? a - b : b - a;
        assertLe(diff, tolerance, "Values not approximately equal");
    }
}