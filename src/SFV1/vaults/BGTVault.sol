// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseVault} from "../BaseVault.sol";

/**
 * @title BGTVault
 * @author Set & Forgetti  
 * @notice ERC-4626 vault for BGT tokens with strategy toggling between swapping and delegation
 * @dev BGT vault implementing flexible strategy allocation between liquid swaps and delegation
 */
contract BGTVault is BaseVault {
    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Delegation strategy address
    address public delegationStrategy;
    
    /// @notice Swap strategy address  
    address public swapStrategy;
    
    /// @notice Current active strategy mode
    StrategyMode public currentMode;
    
    /// @notice Performance fee in basis points
    uint256 public performanceFee;
    
    /// @notice Target allocation for delegation vs swap (in BPS, 10000 = 100% delegation)
    uint256 public targetDelegationAllocation;
    
    /// @notice Rebalance threshold in basis points (triggers rebalance when allocation deviates)
    uint256 public rebalanceThreshold;
    
    /// @notice Fee recipient address
    address public feeRecipient;
    
    /// @notice BGT delegation validator address
    address public validator;

    /*//////////////////////////////////////////////////////////////
                                 ENUMS
    //////////////////////////////////////////////////////////////*/

    enum StrategyMode {
        DELEGATION_ONLY,    // 100% delegation
        SWAP_ONLY,         // 100% liquid swaps
        MIXED              // Mix of both strategies
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event StrategyModeChanged(StrategyMode oldMode, StrategyMode newMode);
    event DelegationAllocationUpdated(uint256 oldAllocation, uint256 newAllocation);
    event RebalanceThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event ValidatorUpdated(address indexed oldValidator, address indexed newValidator);
    event StrategiesRebalanced(uint256 delegationDebt, uint256 swapDebt);
    event PerformanceFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidAllocation();
    error InvalidStrategyMode();
    error StrategyNotSet();
    error RebalanceNotNeeded();

    /*//////////////////////////////////////////////////////////////
                               INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the BGTVault
     * @param bgtToken The BGT token address
     * @param validator_ Initial validator for delegation
     * @param admin The admin address
     * @param strategist The strategist address
     * @param keeper The keeper address
     * @param feeRecipient_ The fee recipient address
     */
    function initialize(
        IERC20 bgtToken,
        address validator_,
        address admin,
        address strategist,
        address keeper,
        address feeRecipient_
    ) external initializer {
        __BaseVault_init(
            bgtToken,
            "Set & Forgetti BGT Vault",
            "sfBGT",
            admin,
            strategist,
            keeper
        );

        validator = validator_;
        feeRecipient = feeRecipient_;
        
        // Initialize BGT-specific parameters
        currentMode = StrategyMode.MIXED;
        targetDelegationAllocation = 7000; // 70% delegation, 30% swap by default
        rebalanceThreshold = 1000; // 10% deviation triggers rebalance
        performanceFee = 2000; // 20% performance fee
        
        // Set vault-specific defaults for BGT
        minimumTotalIdle = 300; // 3% idle buffer for instant withdrawals
    }

    /*//////////////////////////////////////////////////////////////
                            STRATEGY MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set the delegation strategy address
     * @param strategy_ Address of the delegation strategy
     */
    function setDelegationStrategy(address strategy_) external onlyStrategist {
        if (strategy_ == address(0)) revert ZeroAddress();
        delegationStrategy = strategy_;
        
        // Add to strategies if not already added
        if (strategies[strategy_].activation == 0) {
            addStrategy(strategy_, type(uint256).max / 2); // Large max debt for delegation
        }
    }

    /**
     * @notice Set the swap strategy address
     * @param strategy_ Address of the swap strategy
     */
    function setSwapStrategy(address strategy_) external onlyStrategist {
        if (strategy_ == address(0)) revert ZeroAddress();
        swapStrategy = strategy_;
        
        // Add to strategies if not already added
        if (strategies[strategy_].activation == 0) {
            addStrategy(strategy_, type(uint256).max / 2); // Large max debt for swaps
        }
    }

    /**
     * @notice Change strategy mode (delegation only, swap only, or mixed)
     * @param newMode New strategy mode to switch to
     */
    function setStrategyMode(StrategyMode newMode) external onlyStrategist {
        StrategyMode oldMode = currentMode;
        currentMode = newMode;
        
        // Adjust target allocations based on mode
        if (newMode == StrategyMode.DELEGATION_ONLY) {
            targetDelegationAllocation = 10000; // 100% delegation
        } else if (newMode == StrategyMode.SWAP_ONLY) {
            targetDelegationAllocation = 0; // 100% swap
        }
        // MIXED mode keeps current targetDelegationAllocation
        
        emit StrategyModeChanged(oldMode, newMode);
        
        // Trigger immediate rebalance
        _rebalanceStrategies();
    }

    /**
     * @notice Set target delegation allocation (only for MIXED mode)
     * @param newAllocation New allocation in basis points (0-10000)
     */
    function setTargetDelegationAllocation(uint256 newAllocation) external onlyStrategist {
        if (newAllocation > 10000) revert InvalidAllocation();
        if (currentMode != StrategyMode.MIXED) revert InvalidStrategyMode();
        
        uint256 oldAllocation = targetDelegationAllocation;
        targetDelegationAllocation = newAllocation;
        emit DelegationAllocationUpdated(oldAllocation, newAllocation);
        
        // Trigger rebalance if threshold exceeded
        if (_shouldRebalance()) {
            _rebalanceStrategies();
        }
    }

    /**
     * @notice Rebalance strategies to match target allocations
     */
    function rebalance() external onlyKeeper nonReentrant whenNotPaused {
        if (!_shouldRebalance()) revert RebalanceNotNeeded();
        _rebalanceStrategies();
    }

    /*//////////////////////////////////////////////////////////////
                            BGT-SPECIFIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Delegate BGT to validator through delegation strategy
     * @param amount Amount of BGT to delegate
     */
    function delegateBGT(uint256 amount) external onlyKeeper {
        if (delegationStrategy == address(0)) revert StrategyNotSet();
        
        // This would call the delegation strategy to delegate BGT
        // Implementation depends on Berachain's delegation mechanism
        _updateDebt(delegationStrategy, strategies[delegationStrategy].currentDebt + amount, maxLoss);
    }

    /**
     * @notice Undelegate BGT from validator
     * @param amount Amount of BGT to undelegate
     */
    function undelegateBGT(uint256 amount) external onlyKeeper {
        if (delegationStrategy == address(0)) revert StrategyNotSet();
        
        uint256 currentDebt = strategies[delegationStrategy].currentDebt;
        uint256 newDebt = currentDebt > amount ? currentDebt - amount : 0;
        _updateDebt(delegationStrategy, newDebt, maxLoss);
    }

    /**
     * @notice Swap BGT for other assets through swap strategy
     * @param amount Amount of BGT to swap
     * @param haikuPayload Haiku calldata for optimal swap execution
     * @param minAmountOut Minimum output expected
     */
    function swapBGT(
        uint256 amount,
        bytes calldata haikuPayload,
        uint256 minAmountOut
    ) external onlyKeeper {
        if (swapStrategy == address(0)) revert StrategyNotSet();
        
        // Execute swap through Haiku adapter
        compoundWithCalldata(swapStrategy, haikuPayload, minAmountOut);
    }

    /**
     * @notice Update validator for BGT delegation
     * @param newValidator New validator address
     */
    function setValidator(address newValidator) external onlyStrategist {
        if (newValidator == address(0)) revert ZeroAddress();
        address oldValidator = validator;
        validator = newValidator;
        emit ValidatorUpdated(oldValidator, newValidator);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get BGT vault information
     * @return info Struct containing BGT vault details
     */
    function getBGTVaultInfo() external view returns (
        StrategyMode mode,
        uint256 totalAssets_,
        uint256 delegationDebt,
        uint256 swapDebt,
        uint256 targetDelegationAllocation_,
        uint256 currentDelegationAllocation,
        bool shouldRebalance,
        address validator_
    ) {
        mode = currentMode;
        totalAssets_ = totalAssets();
        delegationDebt = delegationStrategy != address(0) ? strategies[delegationStrategy].currentDebt : 0;
        swapDebt = swapStrategy != address(0) ? strategies[swapStrategy].currentDebt : 0;
        targetDelegationAllocation_ = targetDelegationAllocation;
        
        uint256 totalStrategyDebt = delegationDebt + swapDebt;
        currentDelegationAllocation = totalStrategyDebt > 0 ? 
            (delegationDebt * 10000) / totalStrategyDebt : 0;
        
        shouldRebalance = _shouldRebalance();
        validator_ = validator;
    }

    /**
     * @notice Check if rebalancing is needed
     * @return needed Whether rebalance is needed
     */
    function shouldRebalance() external view returns (bool needed) {
        return _shouldRebalance();
    }

    /**
     * @notice Get delegation rewards information
     * @return pendingRewards Pending delegation rewards
     * @return totalDelegated Total BGT delegated
     */
    function getDelegationInfo() external view returns (
        uint256 pendingRewards,
        uint256 totalDelegated
    ) {
        if (delegationStrategy == address(0)) {
            return (0, 0);
        }
        
        totalDelegated = strategies[delegationStrategy].currentDebt;
        // pendingRewards would be queried from the delegation strategy
        // Implementation depends on Berachain's delegation rewards mechanism
        pendingRewards = 0; // Placeholder
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Check if strategies should be rebalanced
     * @return shouldRebalance Whether rebalance is needed
     */
    function _shouldRebalance() internal view returns (bool shouldRebalance) {
        if (delegationStrategy == address(0) || swapStrategy == address(0)) {
            return false;
        }
        
        uint256 delegationDebt = strategies[delegationStrategy].currentDebt;
        uint256 swapDebt = strategies[swapStrategy].currentDebt;
        uint256 totalStrategyDebt = delegationDebt + swapDebt;
        
        if (totalStrategyDebt == 0) return false;
        
        uint256 currentDelegationAllocation = (delegationDebt * 10000) / totalStrategyDebt;
        uint256 deviation = currentDelegationAllocation > targetDelegationAllocation ?
            currentDelegationAllocation - targetDelegationAllocation :
            targetDelegationAllocation - currentDelegationAllocation;
        
        return deviation >= rebalanceThreshold;
    }

    /**
     * @notice Internal function to rebalance strategies
     */
    function _rebalanceStrategies() internal {
        if (delegationStrategy == address(0) || swapStrategy == address(0)) {
            return;
        }
        
        uint256 totalAssets_ = totalAssets();
        uint256 targetIdle = (totalAssets_ * minimumTotalIdle) / MAX_BPS;
        uint256 availableForStrategies = totalAssets_ > targetIdle ? totalAssets_ - targetIdle : 0;
        
        uint256 targetDelegationDebt = (availableForStrategies * targetDelegationAllocation) / MAX_BPS;
        uint256 targetSwapDebt = availableForStrategies - targetDelegationDebt;
        
        // Update debt allocations
        _updateDebt(delegationStrategy, targetDelegationDebt, maxLoss);
        _updateDebt(swapStrategy, targetSwapDebt, maxLoss);
        
        emit StrategiesRebalanced(targetDelegationDebt, targetSwapDebt);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set rebalance threshold
     * @param newThreshold New threshold in basis points
     */
    function setRebalanceThreshold(uint256 newThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newThreshold > 5000) revert InvalidAllocation(); // Max 50% deviation
        uint256 oldThreshold = rebalanceThreshold;
        rebalanceThreshold = newThreshold;
        emit RebalanceThresholdUpdated(oldThreshold, newThreshold);
    }

    /**
     * @notice Set performance fee
     * @param newFee New performance fee in basis points
     */
    function setPerformanceFee(uint256 newFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFee > 5000) revert InvalidFee(); // Max 50%
        uint256 oldFee = performanceFee;
        performanceFee = newFee;
        emit PerformanceFeeUpdated(oldFee, newFee);
    }

    /**
     * @notice Set fee recipient
     * @param newRecipient New fee recipient address
     */
    function setFeeRecipient(address newRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRecipient == address(0)) revert ZeroAddress();
        address oldRecipient = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(oldRecipient, newRecipient);
    }

    /*//////////////////////////////////////////////////////////////
                           EMERGENCY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emergency switch to swap-only mode
     * @dev Can be called in case delegation has issues
     */
    function emergencySwapMode() external onlyRole(DEFAULT_ADMIN_ROLE) {
        currentMode = StrategyMode.SWAP_ONLY;
        targetDelegationAllocation = 0;
        
        // Force withdraw from delegation strategy
        if (delegationStrategy != address(0)) {
            _updateDebt(delegationStrategy, 0, 1000); // 10% max loss in emergency
        }
        
        emit StrategyModeChanged(StrategyMode.MIXED, StrategyMode.SWAP_ONLY);
    }

    /**
     * @notice Emergency switch to delegation-only mode
     * @dev Can be called if swap strategies are compromised
     */
    function emergencyDelegationMode() external onlyRole(DEFAULT_ADMIN_ROLE) {
        currentMode = StrategyMode.DELEGATION_ONLY;
        targetDelegationAllocation = 10000;
        
        // Force withdraw from swap strategy
        if (swapStrategy != address(0)) {
            _updateDebt(swapStrategy, 0, 1000); // 10% max loss in emergency
        }
        
        emit StrategyModeChanged(StrategyMode.MIXED, StrategyMode.DELEGATION_ONLY);
    }
}