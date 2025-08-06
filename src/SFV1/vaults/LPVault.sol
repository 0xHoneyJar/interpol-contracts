// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseVault} from "../BaseVault.sol";

/**
 * @title LPVault  
 * @author Set & Forgetti
 * @notice ERC-4626 vault for WBERA-ETH LP tokens with auto-compounding via Haiku
 * @dev LP vault implementing yield farming strategies with MasterChef staking
 */
contract LPVault is BaseVault {
    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice LP token pair information
    address public token0; // WBERA
    address public token1; // ETH
    
    /// @notice DEX pool address for the LP
    address public pool;
    
    /// @notice Performance fee in basis points
    uint256 public performanceFee;
    
    /// @notice Auto-compound frequency in seconds
    uint256 public autoCompoundFrequency;
    
    /// @notice Last auto-compound timestamp
    uint256 public lastAutoCompound;
    
    /// @notice Minimum LP tokens needed for auto-compound
    uint256 public minAutoCompoundAmount;
    
    /// @notice Fee recipient address
    address public feeRecipient;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event AutoCompoundExecuted(uint256 rewardsCompounded, uint256 lpMinted);
    event AutoCompoundFrequencyUpdated(uint256 oldFrequency, uint256 newFrequency);
    event MinAutoCompoundAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event PerformanceFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error AutoCompoundTooSoon();
    error InsufficientRewardsForCompound();
    error InvalidToken();

    /*//////////////////////////////////////////////////////////////
                               INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the LPVault
     * @param lpToken The LP token address (WBERA-ETH)
     * @param token0_ WBERA token address
     * @param token1_ ETH token address
     * @param pool_ DEX pool address
     * @param admin The admin address
     * @param strategist The strategist address
     * @param keeper The keeper address
     * @param feeRecipient_ The fee recipient address
     */
    function initialize(
        IERC20 lpToken,
        address token0_,
        address token1_,
        address pool_,
        address admin,
        address strategist,
        address keeper,
        address feeRecipient_
    ) external initializer {
        __BaseVault_init(
            lpToken,
            "Set & Forgetti WBERA-ETH LP Vault",
            "sfWBERA-ETH",
            admin,
            strategist,
            keeper
        );

        token0 = token0_;
        token1 = token1_;
        pool = pool_;
        feeRecipient = feeRecipient_;
        
        // Initialize LP-specific parameters
        performanceFee = 2000; // 20% performance fee
        autoCompoundFrequency = 8 hours; // Auto-compound every 8 hours
        minAutoCompoundAmount = 1e18; // Minimum 1 LP token for auto-compound
        lastAutoCompound = block.timestamp;
        
        // Set vault-specific defaults for LP
        minimumTotalIdle = 200; // 2% idle buffer for LP instant withdrawals
    }

    /*//////////////////////////////////////////////////////////////
                            AUTO-COMPOUND FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Auto-compound LP rewards using Haiku calldata
     * @param strategy Address of the strategy to compound
     * @param haikuPayload Signed calldata from Haiku API for optimal swaps
     * @param minLPOut Minimum LP tokens expected from compounding
     */
    function autoCompound(
        address strategy,
        bytes calldata haikuPayload,
        uint256 minLPOut
    ) external onlyKeeper nonReentrant whenNotPaused {
        if (block.timestamp < lastAutoCompound + autoCompoundFrequency) {
            revert AutoCompoundTooSoon();
        }

        // Check if strategy has enough rewards to compound
        if (!_shouldAutoCompound(strategy)) {
            revert InsufficientRewardsForCompound();
        }

        uint256 lpBefore = IERC20(asset()).balanceOf(address(this));
        
        // Execute compound with Haiku calldata
        compoundWithCalldata(strategy, haikuPayload, minLPOut);
        
        uint256 lpAfter = IERC20(asset()).balanceOf(address(this));
        uint256 lpMinted = lpAfter - lpBefore;
        
        lastAutoCompound = block.timestamp;
        
        emit AutoCompoundExecuted(0, lpMinted); // rewards amount could be passed from strategy
    }

    /**
     * @notice Manual compound trigger for specific strategy
     * @param strategy Address of the strategy to compound manually
     */
    function manualCompound(address strategy) external onlyKeeper {
        if (!strategies[strategy].isActive) revert StrategyNotActive();
        _processReport(strategy);
        
        // Collect performance fees on compound
        // Performance fees would be calculated based on strategy profits
    }

    /*//////////////////////////////////////////////////////////////
                            LP-SPECIFIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Add liquidity to LP using individual tokens
     * @param amount0 Amount of token0 to add
     * @param amount1 Amount of token1 to add
     * @param minLPOut Minimum LP tokens expected
     * @return lpReceived LP tokens received
     */
    function addLiquidityDirect(
        uint256 amount0,
        uint256 amount1,
        uint256 minLPOut
    ) external onlyKeeper returns (uint256 lpReceived) {
        // This would integrate with the specific DEX's add liquidity function
        // For now, it's a placeholder for the actual implementation
        
        // Transfer tokens from caller
        if (amount0 > 0) {
            IERC20(token0).transferFrom(msg.sender, address(this), amount0);
        }
        if (amount1 > 0) {
            IERC20(token1).transferFrom(msg.sender, address(this), amount1);
        }
        
        // Add liquidity through DEX (implementation depends on specific DEX)
        // This is where you'd call the actual DEX's addLiquidity function
        
        return lpReceived;
    }

    /**
     * @notice Remove liquidity and receive individual tokens
     * @param lpAmount Amount of LP tokens to remove
     * @param min0Out Minimum token0 expected
     * @param min1Out Minimum token1 expected
     * @return amount0 Amount of token0 received
     * @return amount1 Amount of token1 received
     */
    function removeLiquidityDirect(
        uint256 lpAmount,
        uint256 min0Out,
        uint256 min1Out
    ) external onlyKeeper returns (uint256 amount0, uint256 amount1) {
        // This would integrate with the specific DEX's remove liquidity function
        // Implementation depends on specific DEX being used
        
        return (amount0, amount1);
    }

    /*//////////////////////////////////////////////////////////////
                            STRATEGY HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize vault with LP farming strategies
     * @param lpMaxiStrategy Address of LP Maxi strategy for MasterChef farming
     * @param initialAllocation Initial debt allocation percentage (BPS)
     */
    function initializeWithStrategies(
        address lpMaxiStrategy,
        uint256 initialAllocation
    ) external onlyStrategist {
        // Add LP Maxi strategy with specified allocation
        uint256 maxDebtAmount = (type(uint256).max * initialAllocation) / MAX_BPS;
        addStrategy(lpMaxiStrategy, maxDebtAmount);
    }

    /**
     * @notice Check if strategy should auto-compound
     * @param strategy Address of the strategy to check
     * @return shouldCompound Whether auto-compound should be triggered
     */
    function _shouldAutoCompound(address strategy) internal view returns (bool shouldCompound) {
        // Check if strategy has minimum rewards accumulated
        // This would query the strategy's pending rewards
        // For now, always return true as placeholder
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS  
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get LP vault information
     * @return info Struct containing LP vault details
     */
    function getLPVaultInfo() external view returns (
        address token0_,
        address token1_,
        address pool_,
        uint256 totalAssets_,
        uint256 totalSupply_,
        uint256 lastAutoCompound_,
        uint256 nextAutoCompound_,
        bool canAutoCompound_
    ) {
        token0_ = token0;
        token1_ = token1;
        pool_ = pool;
        totalAssets_ = totalAssets();
        totalSupply_ = totalSupply();
        lastAutoCompound_ = lastAutoCompound;
        nextAutoCompound_ = lastAutoCompound + autoCompoundFrequency;
        canAutoCompound_ = block.timestamp >= nextAutoCompound_;
    }

    /**
     * @notice Preview LP tokens received for token amounts
     * @param amount0 Amount of token0
     * @param amount1 Amount of token1
     * @return lpOut Expected LP tokens
     */
    function previewAddLiquidity(
        uint256 amount0,
        uint256 amount1
    ) external view returns (uint256 lpOut) {
        // This would calculate expected LP based on current pool ratios
        // Implementation depends on specific DEX
        return lpOut;
    }

    /**
     * @notice Preview token amounts for LP removal
     * @param lpAmount Amount of LP tokens to remove
     * @return amount0 Expected token0 amount
     * @return amount1 Expected token1 amount
     */
    function previewRemoveLiquidity(
        uint256 lpAmount
    ) external view returns (uint256 amount0, uint256 amount1) {
        // This would calculate expected tokens based on current pool ratios
        // Implementation depends on specific DEX
        return (amount0, amount1);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set auto-compound frequency
     * @param newFrequency New frequency in seconds
     */
    function setAutoCompoundFrequency(uint256 newFrequency) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newFrequency >= 1 hours && newFrequency <= 7 days, "Invalid frequency");
        uint256 oldFrequency = autoCompoundFrequency;
        autoCompoundFrequency = newFrequency;
        emit AutoCompoundFrequencyUpdated(oldFrequency, newFrequency);
    }

    /**
     * @notice Set minimum auto-compound amount
     * @param newAmount New minimum amount
     */
    function setMinAutoCompoundAmount(uint256 newAmount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldAmount = minAutoCompoundAmount;
        minAutoCompoundAmount = newAmount;
        emit MinAutoCompoundAmountUpdated(oldAmount, newAmount);
    }

    /**
     * @notice Set performance fee
     * @param newFee New performance fee in basis points
     */
    function setPerformanceFee(uint256 newFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newFee <= 5000, "Fee too high"); // Max 50%
        uint256 oldFee = performanceFee;
        performanceFee = newFee;
        emit PerformanceFeeUpdated(oldFee, newFee);
    }

    /**
     * @notice Set fee recipient
     * @param newRecipient New fee recipient address
     */
    function setFeeRecipient(address newRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newRecipient != address(0), "Zero address");
        address oldRecipient = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(oldRecipient, newRecipient);
    }

    /*//////////////////////////////////////////////////////////////
                           EMERGENCY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emergency pause auto-compounding
     */
    function pauseAutoCompound() external onlyRole(DEFAULT_ADMIN_ROLE) {
        autoCompoundFrequency = type(uint256).max; // Effectively disable
    }

    /**
     * @notice Resume auto-compounding with frequency
     * @param frequency New frequency in seconds
     */
    function resumeAutoCompound(uint256 frequency) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(frequency >= 1 hours && frequency <= 7 days, "Invalid frequency");
        autoCompoundFrequency = frequency;
        lastAutoCompound = block.timestamp;
    }
}