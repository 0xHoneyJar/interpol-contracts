// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaseStrategy} from "./BaseStrategy.sol";
import {IMasterChef, IDEXRouter} from "../interfaces/IMasterChef.sol";

/**
 * @title LPMaxiStrategy
 * @author Set & Forgetti
 * @notice Strategy for LP farming in MasterChef-style contracts with auto-compounding
 * @dev Implements LP token staking with reward farming and Haiku-powered compounding
 */
contract LPMaxiStrategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice MasterChef contract address
    address public masterChef;
    
    /// @notice Pool ID in MasterChef
    uint256 public poolId;
    
    /// @notice Primary reward token address
    address public rewardToken;
    
    /// @notice Secondary reward token (if any)
    address public secondaryRewardToken;
    
    /// @notice LP token components
    address public token0;
    address public token1;
    
    /// @notice DEX router for adding liquidity
    address public router;
    
    /// @notice Minimum harvest amount for each reward token
    uint256 public minHarvestAmount;
    uint256 public minSecondaryHarvestAmount;
    
    /// @notice Last known staked LP amount
    uint256 public stakedLPAmount;
    
    /// @notice Harvest frequency in seconds
    uint256 public harvestFrequency;
    
    /// @notice Last harvest timestamp
    uint256 public lastHarvestTime;
    
    /// @notice Auto-compound settings
    bool public autoCompoundEnabled;
    uint256 public compoundSlippage; // in basis points

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event LPStaked(uint256 amount);
    event LPUnstaked(uint256 amount);
    event RewardsHarvested(uint256 primaryRewards, uint256 secondaryRewards);
    event LiquidityAdded(uint256 token0Amount, uint256 token1Amount, uint256 lpReceived);
    event AutoCompoundExecuted(uint256 lpCompounded);
    event HarvestParametersUpdated(uint256 minAmount, uint256 frequency);
    event MasterChefUpdated(address indexed oldChef, address indexed newChef);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error MasterChefNotSet();
    error RouterNotSet();
    error InsufficientLPAmount();
    error AutoCompoundDisabled();
    error InvalidSlippage();



    /*//////////////////////////////////////////////////////////////
                               INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the LPMaxiStrategy
     * @param lpToken The LP token address (WBERA-ETH)
     * @param masterChef_ The MasterChef contract address
     * @param poolId_ The pool ID in MasterChef
     * @param router_ The DEX router address
     * @param token0_ Token0 of the LP pair
     * @param token1_ Token1 of the LP pair
     * @param vault_ The vault address
     * @param management_ The management address
     * @param keeper_ The keeper address
     */
    function initialize(
        address lpToken,
        address masterChef_,
        uint256 poolId_,
        address router_,
        address token0_,
        address token1_,
        address vault_,
        address management_,
        address keeper_
    ) external initializer {
        __BaseStrategy_init(
            lpToken,
            "LP Maxi Strategy",
            vault_,
            management_,
            keeper_
        );

        masterChef = masterChef_;
        poolId = poolId_;
        router = router_;
        token0 = token0_;
        token1 = token1_;
        
        // Initialize strategy parameters
        minHarvestAmount = 1e18; // 1 token minimum for harvest
        minSecondaryHarvestAmount = 1e18;
        harvestFrequency = 8 hours; // Harvest every 8 hours
        lastHarvestTime = block.timestamp;
        autoCompoundEnabled = true;
        compoundSlippage = 200; // 2% slippage tolerance
        
        // Approve contracts to spend tokens
        IERC20(lpToken).safeApprove(masterChef_, type(uint256).max);
        IERC20(token0_).safeApprove(router_, type(uint256).max);
        IERC20(token1_).safeApprove(router_, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                        STRATEGY IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Deploy LP tokens to MasterChef farming
     * @param assets Amount of LP tokens to stake
     */
    function _deployFunds(uint256 assets) internal override {
        if (masterChef == address(0)) revert MasterChefNotSet();
        
        // Stake LP tokens in MasterChef
        IMasterChef(masterChef).deposit(poolId, assets);
        stakedLPAmount += assets;
        
        emit LPStaked(assets);
    }

    /**
     * @dev Free LP tokens from MasterChef farming
     * @param amount Amount of LP tokens to unstake
     * @return actualAmount Actual amount unstaked
     */
    function _freeFunds(uint256 amount) internal override returns (uint256 actualAmount) {
        if (masterChef == address(0)) revert MasterChefNotSet();
        
        uint256 availableToUnstake = stakedLPAmount;
        actualAmount = Math.min(amount, availableToUnstake);
        
        if (actualAmount == 0) return 0;
        
        // Unstake LP tokens from MasterChef
        IMasterChef(masterChef).withdraw(poolId, actualAmount);
        stakedLPAmount -= actualAmount;
        
        emit LPUnstaked(actualAmount);
        return actualAmount;
    }

    /**
     * @dev Harvest rewards and report performance
     * @return profit Amount of profit generated
     * @return loss Amount of loss incurred
     */
    function _harvestAndReport() internal override returns (uint256 profit, uint256 loss) {
        if (masterChef == address(0)) return (0, 0);
        
        uint256 lpBefore = totalAssets();
        
        // Harvest rewards by depositing 0 (triggers reward claim)
        IMasterChef(masterChef).deposit(poolId, 0);
        
        // Get reward token balances
        uint256 primaryRewards = rewardToken != address(0) ? 
            IERC20(rewardToken).balanceOf(address(this)) : 0;
        uint256 secondaryRewards = secondaryRewardToken != address(0) ? 
            IERC20(secondaryRewardToken).balanceOf(address(this)) : 0;
        
        emit RewardsHarvested(primaryRewards, secondaryRewards);
        
        // Auto-compound if enabled and we have enough rewards
        if (autoCompoundEnabled && _shouldAutoCompound(primaryRewards, secondaryRewards)) {
            _autoCompound(primaryRewards, secondaryRewards);
        }
        
        uint256 lpAfter = totalAssets();
        
        if (lpAfter > lpBefore) {
            profit = lpAfter - lpBefore;
        } else if (lpAfter < lpBefore) {
            loss = lpBefore - lpAfter;
        }
        
        lastHarvestTime = block.timestamp;
        return (profit, loss);
    }

    /**
     * @dev Check if strategy should be tended
     * @return shouldTend Whether tending is needed
     * @return calldata_ Optional calldata
     */
    function _tendTrigger() internal view override returns (bool shouldTend, bytes memory calldata_) {
        // Tend if enough time has passed and there are pending rewards
        uint256 pendingRewards = _getPendingRewards();
        bool enoughTime = block.timestamp >= lastHarvestTime + harvestFrequency;
        bool enoughRewards = pendingRewards >= minHarvestAmount;
        
        shouldTend = enoughTime && enoughRewards;
        return (shouldTend, "");
    }

    /**
     * @dev Perform strategy maintenance (harvest and compound)
     * @param totalIdle Total idle assets in vault
     */
    function _tendThis(uint256 totalIdle) internal override {
        // Harvest and compound rewards
        _harvestAndReport();
    }

    /**
     * @dev Called after Haiku compound execution
     * @param amountOut Amount of LP received from Haiku operation
     */
    function _afterHaikuCompound(uint256 amountOut) internal override {
        // If we received LP tokens from Haiku compounding, stake them
        if (amountOut > 0) {
            _deployFunds(amountOut);
        }
    }

    /*//////////////////////////////////////////////////////////////
                           AUTO-COMPOUND LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Auto-compound rewards into more LP tokens
     * @param primaryRewards Amount of primary reward tokens
     * @param secondaryRewards Amount of secondary reward tokens
     */
    function _autoCompound(uint256 primaryRewards, uint256 secondaryRewards) internal {
        if (router == address(0)) revert RouterNotSet();
        
        uint256 lpBefore = IERC20(asset()).balanceOf(address(this));
        
        // Convert rewards to LP tokens through optimal routing
        if (primaryRewards > 0) {
            _convertRewardsToLP(rewardToken, primaryRewards);
        }
        
        if (secondaryRewards > 0) {
            _convertRewardsToLP(secondaryRewardToken, secondaryRewards);
        }
        
        uint256 lpAfter = IERC20(asset()).balanceOf(address(this));
        uint256 lpCompounded = lpAfter - lpBefore;
        
        if (lpCompounded > 0) {
            // Stake the newly created LP tokens
            _deployFunds(lpCompounded);
            emit AutoCompoundExecuted(lpCompounded);
        }
    }

    /**
     * @dev Convert reward tokens to LP tokens
     * @param rewardTokenAddr Reward token address
     * @param amount Amount of reward tokens to convert
     */
    function _convertRewardsToLP(address rewardTokenAddr, uint256 amount) internal {
        if (amount == 0 || rewardTokenAddr == address(0)) return;
        
        // Split rewards 50/50 for each token in the pair
        uint256 halfAmount = amount / 2;
        
        uint256 token0Amount;
        uint256 token1Amount;
        
        // Convert to token0
        if (rewardTokenAddr == token0) {
            token0Amount = halfAmount;
        } else {
            token0Amount = _swapToken(rewardTokenAddr, token0, halfAmount);
        }
        
        // Convert to token1
        if (rewardTokenAddr == token1) {
            token1Amount = amount - halfAmount;
        } else {
            token1Amount = _swapToken(rewardTokenAddr, token1, amount - halfAmount);
        }
        
        // Add liquidity
        if (token0Amount > 0 && token1Amount > 0) {
            _addLiquidity(token0Amount, token1Amount);
        }
    }

    /**
     * @dev Swap one token for another using DEX router
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Input token amount
     * @return amountOut Output token amount received
     */
    function _swapToken(address tokenIn, address tokenOut, uint256 amountIn) 
        internal 
        returns (uint256 amountOut) 
    {
        if (tokenIn == tokenOut || amountIn == 0) return amountIn;
        
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        
        // Calculate minimum output with slippage protection
        uint256[] memory amounts = IDEXRouter(router).getAmountsOut(amountIn, path);
        uint256 minAmountOut = (amounts[1] * (MAX_BPS - compoundSlippage)) / MAX_BPS;
        
        uint256[] memory swapAmounts = IDEXRouter(router).swapExactTokensForTokens(
            amountIn,
            minAmountOut,
            path,
            address(this),
            block.timestamp + 300 // 5 minute deadline
        );
        
        return swapAmounts[1];
    }

    /**
     * @dev Add liquidity to create LP tokens
     * @param amount0 Amount of token0
     * @param amount1 Amount of token1
     */
    function _addLiquidity(uint256 amount0, uint256 amount1) internal {
        // Calculate minimum amounts with slippage protection
        uint256 minAmount0 = (amount0 * (MAX_BPS - compoundSlippage)) / MAX_BPS;
        uint256 minAmount1 = (amount1 * (MAX_BPS - compoundSlippage)) / MAX_BPS;
        
        (uint256 actualAmount0, uint256 actualAmount1, uint256 lpReceived) = IDEXRouter(router).addLiquidity(
            token0,
            token1,
            amount0,
            amount1,
            minAmount0,
            minAmount1,
            address(this),
            block.timestamp + 300 // 5 minute deadline
        );
        
        emit LiquidityAdded(actualAmount0, actualAmount1, lpReceived);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get total assets under management
     * @return Total LP assets (staked + idle)
     */
    function totalAssets() public view override returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        return idle + stakedLPAmount;
    }

    /**
     * @notice Get pending rewards from MasterChef
     * @return Pending reward amount
     */
    function getPendingRewards() external view returns (uint256) {
        return _getPendingRewards();
    }

    /**
     * @notice Get strategy information
     * @return info Struct containing strategy details
     */
    function getStrategyInfo() external view returns (
        uint256 totalAssets_,
        uint256 stakedLPAmount_,
        uint256 idleAssets_,
        uint256 pendingRewards_,
        uint256 lastHarvest_,
        uint256 nextHarvest_,
        bool canHarvest_,
        bool autoCompoundEnabled_
    ) {
        totalAssets_ = totalAssets();
        stakedLPAmount_ = stakedLPAmount;
        idleAssets_ = IERC20(asset()).balanceOf(address(this));
        pendingRewards_ = _getPendingRewards();
        lastHarvest_ = lastHarvestTime;
        nextHarvest_ = lastHarvestTime + harvestFrequency;
        canHarvest_ = block.timestamp >= nextHarvest_ && pendingRewards_ >= minHarvestAmount;
        autoCompoundEnabled_ = autoCompoundEnabled;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Get pending rewards from MasterChef
     * @return Pending reward amount
     */
    function _getPendingRewards() internal view returns (uint256) {
        if (masterChef == address(0)) return 0;
        
        try IMasterChef(masterChef).pendingReward(poolId, address(this)) returns (uint256 pending) {
            return pending;
        } catch {
            return 0;
        }
    }

    /**
     * @dev Check if auto-compound should be triggered
     * @param primaryRewards Amount of primary rewards
     * @param secondaryRewards Amount of secondary rewards
     * @return shouldCompound Whether to auto-compound
     */
    function _shouldAutoCompound(uint256 primaryRewards, uint256 secondaryRewards) 
        internal 
        view 
        returns (bool shouldCompound) 
    {
        return primaryRewards >= minHarvestAmount || secondaryRewards >= minSecondaryHarvestAmount;
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Update MasterChef contract
     * @param newMasterChef New MasterChef address
     * @param newPoolId New pool ID
     */
    function setMasterChef(address newMasterChef, uint256 newPoolId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMasterChef == address(0)) revert ZeroAddress();
        
        // Emergency withdraw from old MasterChef if needed
        if (masterChef != address(0) && stakedLPAmount > 0) {
            IMasterChef(masterChef).emergencyWithdraw(poolId);
            stakedLPAmount = 0;
        }
        
        address oldChef = masterChef;
        masterChef = newMasterChef;
        poolId = newPoolId;
        
        // Approve new MasterChef
        IERC20(asset()).safeApprove(newMasterChef, type(uint256).max);
        
        // Re-stake if we have LP tokens
        uint256 toStake = IERC20(asset()).balanceOf(address(this));
        if (toStake > 0) {
            IMasterChef(masterChef).deposit(poolId, toStake);
            stakedLPAmount = toStake;
        }
        
        emit MasterChefUpdated(oldChef, newMasterChef);
    }

    /**
     * @notice Update auto-compound settings
     * @param enabled Whether auto-compound is enabled
     * @param slippage Slippage tolerance in basis points
     */
    function setAutoCompoundSettings(bool enabled, uint256 slippage) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (slippage > 1000) revert InvalidSlippage(); // Max 10% slippage
        
        autoCompoundEnabled = enabled;
        compoundSlippage = slippage;
    }

    /**
     * @notice Update harvest parameters
     * @param newMinAmount New minimum harvest amount for primary rewards
     * @param newMinSecondaryAmount New minimum harvest amount for secondary rewards  
     * @param newFrequency New harvest frequency
     */
    function setHarvestParameters(
        uint256 newMinAmount, 
        uint256 newMinSecondaryAmount,
        uint256 newFrequency
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newFrequency >= 1 hours && newFrequency <= 7 days, "Invalid frequency");
        
        minHarvestAmount = newMinAmount;
        minSecondaryHarvestAmount = newMinSecondaryAmount;
        harvestFrequency = newFrequency;
        
        emit HarvestParametersUpdated(newMinAmount, newFrequency);
    }

    /*//////////////////////////////////////////////////////////////
                           EMERGENCY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emergency withdraw all LP tokens from MasterChef
     */
    function emergencyWithdrawAll() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (masterChef != address(0) && stakedLPAmount > 0) {
            IMasterChef(masterChef).emergencyWithdraw(poolId);
            stakedLPAmount = 0;
        }
    }
}