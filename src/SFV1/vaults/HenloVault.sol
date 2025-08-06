// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseVault} from "../BaseVault.sol";

/**
 * @title HenloVault
 * @author Set & Forgetti
 * @notice ERC-4626 vault for HENLO token with multi-strategy allocation
 * @dev Single-asset vault implementing Yearn V3 allocator pattern for HENLO
 */
contract HenloVault is BaseVault {
    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum deposit limit for this vault
    uint256 public depositLimit;
    
    /// @notice Performance fee in basis points
    uint256 public performanceFee;
    
    /// @notice Management fee in basis points (annual)
    uint256 public managementFee;
    
    /// @notice Last management fee collection timestamp
    uint256 public lastFeeCollection;
    
    /// @notice Fee recipient address
    address public feeRecipient;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event DepositLimitUpdated(uint256 oldLimit, uint256 newLimit);
    event PerformanceFeeUpdated(uint256 oldFee, uint256 newFee);
    event ManagementFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event FeesCollected(uint256 managementFees, uint256 performanceFees);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error DepositLimitExceeded();
    error InvalidFee();

    /*//////////////////////////////////////////////////////////////
                               INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the HenloVault
     * @param henloToken The HENLO token address
     * @param admin The admin address
     * @param strategist The strategist address
     * @param keeper The keeper address
     * @param feeRecipient_ The fee recipient address
     */
    function initialize(
        IERC20 henloToken,
        address admin,
        address strategist,
        address keeper,
        address feeRecipient_
    ) external initializer {
        __BaseVault_init(
            henloToken,
            "Set & Forgetti HENLO Vault",
            "sfHENLO",
            admin,
            strategist,
            keeper
        );

        // Initialize HENLO-specific parameters
        depositLimit = 1_000_000 * 1e18; // 1M HENLO default limit
        performanceFee = 2000; // 20% performance fee
        managementFee = 200; // 2% annual management fee
        lastFeeCollection = block.timestamp;
        feeRecipient = feeRecipient_;

        // Set vault-specific defaults
        minimumTotalIdle = 500; // 5% idle buffer for instant withdrawals
    }

    /*//////////////////////////////////////////////////////////////
                            DEPOSIT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Override maxDeposit to enforce deposit limits
     * @param to Address receiving the shares
     * @return Maximum deposit amount
     */
    function maxDeposit(address to) public view override returns (uint256) {
        if (paused()) return 0;
        
        uint256 currentAssets = totalAssets();
        if (currentAssets >= depositLimit) return 0;
        
        return depositLimit - currentAssets;
    }

    /**
     * @notice Override maxMint to enforce deposit limits
     * @param to Address receiving the shares
     * @return Maximum mint amount
     */
    function maxMint(address to) public view override returns (uint256) {
        uint256 maxAssets = maxDeposit(to);
        return maxAssets == 0 ? 0 : convertToShares(maxAssets);
    }

    /**
     * @notice Override _deposit to check deposit limits
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
    {
        if (totalAssets() + assets > depositLimit) revert DepositLimitExceeded();
        super._deposit(caller, receiver, assets, shares);
    }

    /*//////////////////////////////////////////////////////////////
                            FEE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Collect management fees
     * @dev Called periodically to collect annual management fees
     */
    function collectManagementFees() external onlyKeeper {
        uint256 timePassed = block.timestamp - lastFeeCollection;
        if (timePassed == 0) return;

        uint256 totalShares = totalSupply();
        if (totalShares == 0) return;

        // Calculate annual management fee
        uint256 annualFeeShares = (totalShares * managementFee * timePassed) / (MAX_BPS * 365 days);
        
        if (annualFeeShares > 0) {
            _mint(feeRecipient, annualFeeShares);
            lastFeeCollection = block.timestamp;
        }
    }

    /**
     * @notice Collect performance fees on strategy harvest
     * @param profit The profit amount to charge fees on
     * @return feeShares Shares minted as performance fees
     */
    function collectPerformanceFees(uint256 profit) external onlyKeeper returns (uint256 feeShares) {
        if (profit == 0 || performanceFee == 0) return 0;

        uint256 feeAmount = (profit * performanceFee) / MAX_BPS;
        feeShares = convertToShares(feeAmount);
        
        if (feeShares > 0) {
            _mint(feeRecipient, feeShares);
        }

        return feeShares;
    }

    /*//////////////////////////////////////////////////////////////
                            STRATEGY HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize vault with default strategies and allocations
     * @param henloStakingStrategy Address of HENLO staking strategy
     * @param initialAllocation Initial debt allocation (e.g., 50% = 5000 BPS)
     */
    function initializeWithStrategies(
        address henloStakingStrategy,
        uint256 initialAllocation
    ) external onlyStrategist {
        // Add HENLO staking strategy with 50% max allocation
        uint256 maxDebtAmount = (depositLimit * initialAllocation) / MAX_BPS;
        addStrategy(henloStakingStrategy, maxDebtAmount);
    }

    /**
     * @notice Rebalance vault to maintain target allocations
     * @dev Can be called by keeper to maintain optimal strategy allocations
     */
    function rebalance() external onlyKeeper {
        uint256 totalAssets_ = totalAssets();
        if (totalAssets_ == 0) return;

        // Ensure minimum idle is maintained
        uint256 targetIdle = (totalAssets_ * minimumTotalIdle) / MAX_BPS;
        uint256 currentIdle = totalIdle();

        if (currentIdle < targetIdle) {
            // Need to withdraw from strategies to maintain idle buffer
            uint256 needed = targetIdle - currentIdle;
            _withdrawFromStrategies(needed);
        }

        // Collect management fees during rebalance
        collectManagementFees();
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set deposit limit
     * @param newLimit New deposit limit
     */
    function setDepositLimit(uint256 newLimit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldLimit = depositLimit;
        depositLimit = newLimit;
        emit DepositLimitUpdated(oldLimit, newLimit);
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
     * @notice Set management fee
     * @param newFee New management fee in basis points
     */
    function setManagementFee(uint256 newFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFee > 1000) revert InvalidFee(); // Max 10%
        uint256 oldFee = managementFee;
        managementFee = newFee;
        emit ManagementFeeUpdated(oldFee, newFee);
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
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get vault information
     * @return info Struct containing vault details
     */
    function getVaultInfo() external view returns (
        uint256 totalAssets_,
        uint256 totalSupply_,
        uint256 totalIdle_,
        uint256 totalDebt_,
        uint256 depositLimit_,
        uint256 performanceFee_,
        uint256 managementFee_
    ) {
        totalAssets_ = totalAssets();
        totalSupply_ = totalSupply();
        totalIdle_ = totalIdle();
        totalDebt_ = totalDebt;
        depositLimit_ = depositLimit;
        performanceFee_ = performanceFee;
        managementFee_ = managementFee;
    }

    /**
     * @notice Calculate expected shares for assets after fees
     * @param assets Amount of assets to deposit
     * @return shares Expected shares after accounting for fees
     */
    function previewDepositAfterFees(uint256 assets) external view returns (uint256 shares) {
        shares = convertToShares(assets);
        
        // Account for management fees that would be collected
        uint256 timePassed = block.timestamp - lastFeeCollection;
        if (timePassed > 0) {
            uint256 totalShares = totalSupply();
            uint256 managementFeeShares = (totalShares * managementFee * timePassed) / (MAX_BPS * 365 days);
            
            // Adjust shares for dilution from management fees
            if (managementFeeShares > 0) {
                shares = (shares * totalShares) / (totalShares + managementFeeShares);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                            EMERGENCY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emergency withdraw from all strategies
     * @dev Only callable by admin in emergency situations
     */
    function emergencyWithdrawAll() external onlyRole(DEFAULT_ADMIN_ROLE) {
        address[] memory strategies_ = getStrategyQueue();
        
        for (uint256 i = 0; i < strategies_.length; ++i) {
            address strategy = strategies_[i];
            if (strategies[strategy].isActive && strategies[strategy].currentDebt > 0) {
                // Force withdraw with higher max loss tolerance in emergency
                _updateDebt(strategy, 0, 1000); // 10% max loss in emergency
                emit EmergencyWithdrawal(strategy, strategies[strategy].currentDebt);
            }
        }
    }
}