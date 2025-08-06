// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IStrategy} from "./interfaces/IStrategy.sol";
import {IHaikuAdapter} from "./interfaces/IHaikuAdapter.sol";

/**
 * @title BaseVault
 * @author Set & Forgetti
 * @notice Base ERC-4626 vault implementing Yearn V3's allocator pattern for Berachain
 * @dev Inherits UUPSUpgradeable, AccessControl, Pausable, ERC4626 for secure multi-strategy vaults
 */
abstract contract BaseVault is 
    UUPSUpgradeable, 
    AccessControlUpgradeable, 
    PausableUpgradeable, 
    ReentrancyGuardUpgradeable,
    ERC4626Upgradeable 
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Role for strategists who can manage strategies and debt allocation
    bytes32 public constant STRATEGIST_ROLE = keccak256("STRATEGIST_ROLE");
    
    /// @notice Role for keepers who can call harvest and tend functions
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    
    /// @notice Maximum basis points (100%)
    uint256 public constant MAX_BPS = 10_000;
    
    /// @notice Maximum number of strategies per vault
    uint256 public constant MAX_STRATEGIES = 20;

    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Strategy parameters for debt management
    struct StrategyParams {
        uint256 activation;      // Timestamp when strategy was added
        uint256 lastReport;      // Timestamp of last report
        uint256 currentDebt;     // Current debt allocated to strategy
        uint256 maxDebt;         // Maximum debt that can be allocated
        bool isActive;           // Whether strategy is active
    }

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Mapping of strategy address to its parameters
    mapping(address => StrategyParams) public strategies;
    
    /// @notice Array of strategy addresses for iteration
    address[] public strategyQueue;
    
    /// @notice Minimum amount of assets to keep as idle buffer for instant withdrawals
    uint256 public minimumTotalIdle;
    
    /// @notice Maximum loss acceptable when withdrawing from strategies (in BPS)
    uint256 public maxLoss;
    
    /// @notice Address of the Haiku adapter for auto-compounding
    address public haikuAdapter;
    
    /// @notice Total debt allocated to all strategies
    uint256 public totalDebt;
    
    /// @notice Profit unlock time in seconds
    uint256 public profitMaxUnlockTime;
    
    /// @notice Last profit update timestamp
    uint256 public lastProfitUpdate;
    
    /// @notice Rate of profit unlocking per second
    uint256 public profitUnlockingRate;
    
    /// @notice Full profit unlock date
    uint256 public fullProfitUnlockDate;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event StrategyAdded(address indexed strategy, uint256 maxDebt);
    event StrategyRevoked(address indexed strategy);
    event DebtUpdated(address indexed strategy, uint256 currentDebt, uint256 newDebt);
    event StrategyReported(
        address indexed strategy,
        uint256 gain,
        uint256 loss,
        uint256 currentDebt,
        uint256 totalFees
    );
    event MinimumTotalIdleUpdated(uint256 oldMinimum, uint256 newMinimum);
    event MaxLossUpdated(uint256 oldMaxLoss, uint256 newMaxLoss);
    event HaikuAdapterUpdated(address indexed oldAdapter, address indexed newAdapter);
    event EmergencyWithdrawal(address indexed strategy, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error StrategyAlreadyActive();
    error StrategyNotActive();
    error StrategyNotFound();
    error InsufficientAssets();
    error ExceedsMaxLoss();
    error InvalidStrategy();
    error TooManyStrategies();
    error DebtExceedsMax();
    error InvalidMaxLoss();
    error ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Ensures only strategist or admin can call function
    modifier onlyStrategist() {
        if (!hasRole(STRATEGIST_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            _checkRole(STRATEGIST_ROLE, msg.sender);
        }
        _;
    }

    /// @notice Ensures only keeper or strategist can call function
    modifier onlyKeeper() {
        if (!hasRole(KEEPER_ROLE, msg.sender) && 
            !hasRole(STRATEGIST_ROLE, msg.sender) && 
            !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            _checkRole(KEEPER_ROLE, msg.sender);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the vault
     * @param asset_ The underlying asset for the vault
     * @param name_ The name of the vault token
     * @param symbol_ The symbol of the vault token
     * @param admin_ The admin address
     * @param strategist_ The strategist address
     * @param keeper_ The keeper address
     */
    function __BaseVault_init(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address admin_,
        address strategist_, 
        address keeper_
    ) internal onlyInitializing {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __ERC4626_init(asset_);
        __ERC20_init(name_, symbol_);

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(STRATEGIST_ROLE, strategist_);
        _grantRole(KEEPER_ROLE, keeper_);

        // Initialize with sensible defaults
        minimumTotalIdle = 100; // 1% as default buffer
        maxLoss = 100; // 1% max loss by default
        profitMaxUnlockTime = 6 hours; // 6 hour unlock period
    }

    /*//////////////////////////////////////////////////////////////
                            STRATEGY MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Add a new strategy to the vault
     * @param strategy Address of the strategy to add
     * @param maxDebt Maximum debt that can be allocated to this strategy
     */
    function addStrategy(address strategy, uint256 maxDebt) 
        external 
        onlyStrategist 
        nonReentrant 
        whenNotPaused 
    {
        if (strategy == address(0)) revert ZeroAddress();
        if (strategies[strategy].activation != 0) revert StrategyAlreadyActive();
        if (strategyQueue.length >= MAX_STRATEGIES) revert TooManyStrategies();
        if (IStrategy(strategy).asset() != asset()) revert InvalidStrategy();

        strategies[strategy] = StrategyParams({
            activation: block.timestamp,
            lastReport: block.timestamp,
            currentDebt: 0,
            maxDebt: maxDebt,
            isActive: true
        });

        strategyQueue.push(strategy);
        emit StrategyAdded(strategy, maxDebt);
    }

    /**
     * @notice Revoke a strategy from the vault
     * @param strategy Address of the strategy to revoke
     */
    function revokeStrategy(address strategy) 
        external 
        onlyStrategist 
        nonReentrant 
        whenNotPaused 
    {
        if (!strategies[strategy].isActive) revert StrategyNotActive();
        
        // Force withdraw all funds from strategy
        uint256 currentDebt = strategies[strategy].currentDebt;
        if (currentDebt > 0) {
            _updateDebt(strategy, 0, maxLoss);
        }

        strategies[strategy].isActive = false;
        _removeFromQueue(strategy);
        
        emit StrategyRevoked(strategy);
    }

    /**
     * @notice Update debt allocation for a strategy
     * @param strategy Address of the strategy
     * @param targetDebt Target debt amount
     * @return actualDebt Actual debt allocated
     */
    function updateDebt(address strategy, uint256 targetDebt) 
        external 
        onlyStrategist 
        nonReentrant 
        whenNotPaused 
        returns (uint256 actualDebt) 
    {
        return _updateDebt(strategy, targetDebt, maxLoss);
    }

    /**
     * @notice Update debt allocation for a strategy with custom max loss
     * @param strategy Address of the strategy
     * @param targetDebt Target debt amount
     * @param maxLoss_ Maximum acceptable loss in basis points
     * @return actualDebt Actual debt allocated
     */
    function updateDebt(address strategy, uint256 targetDebt, uint256 maxLoss_) 
        external 
        onlyStrategist 
        nonReentrant 
        whenNotPaused 
        returns (uint256 actualDebt) 
    {
        return _updateDebt(strategy, targetDebt, maxLoss_);
    }

    /*//////////////////////////////////////////////////////////////
                            HARVEST FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Harvest and report strategy performance
     * @param strategy Address of the strategy to harvest
     */
    function harvest(address strategy) 
        external 
        onlyKeeper 
        nonReentrant 
        whenNotPaused 
    {
        if (!strategies[strategy].isActive) revert StrategyNotActive();
        _processReport(strategy);
    }

    /**
     * @notice Harvest multiple strategies
     * @param strategiesToHarvest Array of strategy addresses to harvest
     */
    function harvestMultiple(address[] calldata strategiesToHarvest) 
        external 
        onlyKeeper 
        nonReentrant 
        whenNotPaused 
    {
        for (uint256 i = 0; i < strategiesToHarvest.length; ++i) {
            if (strategies[strategiesToHarvest[i]].isActive) {
                _processReport(strategiesToHarvest[i]);
            }
        }
    }

    /**
     * @notice Auto-compound using Haiku calldata
     * @param strategy Address of the strategy to compound
     * @param haikuPayload Signed calldata from Haiku API
     * @param minAmountOut Minimum expected output for slippage protection
     */
    function compoundWithCalldata(
        address strategy,
        bytes calldata haikuPayload,
        uint256 minAmountOut
    ) external onlyKeeper nonReentrant whenNotPaused {
        if (!strategies[strategy].isActive) revert StrategyNotActive();
        if (haikuAdapter == address(0)) revert ZeroAddress();
        
        // Execute Haiku calldata through adapter
        IHaikuAdapter(haikuAdapter).executeHaikuCalldata(haikuPayload, minAmountOut);
        
        // Process strategy report after compounding
        _processReport(strategy);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get total assets under management
     * @return Total assets in vault and strategies
     */
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + totalDebt;
    }

    /**
     * @notice Get total idle assets in vault
     * @return Idle asset balance
     */
    function totalIdle() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /**
     * @notice Get strategy queue
     * @return Array of strategy addresses
     */
    function getStrategyQueue() external view returns (address[] memory) {
        return strategyQueue;
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set minimum total idle amount
     * @param newMinimum New minimum idle amount in basis points
     */
    function setMinimumTotalIdle(uint256 newMinimum) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (newMinimum > 1000) revert InvalidMaxLoss(); // Max 10%
        uint256 oldMinimum = minimumTotalIdle;
        minimumTotalIdle = newMinimum;
        emit MinimumTotalIdleUpdated(oldMinimum, newMinimum);
    }

    /**
     * @notice Set maximum acceptable loss
     * @param newMaxLoss New max loss in basis points
     */
    function setMaxLoss(uint256 newMaxLoss) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (newMaxLoss > 1000) revert InvalidMaxLoss(); // Max 10%
        uint256 oldMaxLoss = maxLoss;
        maxLoss = newMaxLoss;
        emit MaxLossUpdated(oldMaxLoss, newMaxLoss);
    }

    /**
     * @notice Set Haiku adapter address
     * @param newAdapter Address of the new Haiku adapter
     */
    function setHaikuAdapter(address newAdapter) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        address oldAdapter = haikuAdapter;
        haikuAdapter = newAdapter;
        emit HaikuAdapterUpdated(oldAdapter, newAdapter);
    }

    /**
     * @notice Pause the vault
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the vault
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Internal function to update strategy debt
     */
    function _updateDebt(
        address strategy, 
        uint256 targetDebt, 
        uint256 maxLoss_
    ) internal returns (uint256 actualDebt) {
        if (!strategies[strategy].isActive) revert StrategyNotActive();
        if (targetDebt > strategies[strategy].maxDebt) revert DebtExceedsMax();

        uint256 currentDebt = strategies[strategy].currentDebt;
        
        if (targetDebt == currentDebt) {
            return currentDebt;
        }

        if (targetDebt > currentDebt) {
            // Allocate more funds to strategy
            uint256 toDeposit = targetDebt - currentDebt;
            uint256 availableAssets = totalIdle();
            
            if (toDeposit > availableAssets) {
                toDeposit = availableAssets;
                targetDebt = currentDebt + toDeposit;
            }

            if (toDeposit > 0) {
                IERC20(asset()).safeTransfer(strategy, toDeposit);
                IStrategy(strategy).deployFunds(toDeposit);
                
                strategies[strategy].currentDebt = targetDebt;
                totalDebt += toDeposit;
            }
        } else {
            // Withdraw funds from strategy
            uint256 toWithdraw = currentDebt - targetDebt;
            uint256 withdrawn = IStrategy(strategy).freeFunds(toWithdraw);
            
            // Check for acceptable loss
            if (withdrawn < toWithdraw) {
                uint256 loss = toWithdraw - withdrawn;
                uint256 maxAcceptableLoss = (currentDebt * maxLoss_) / MAX_BPS;
                if (loss > maxAcceptableLoss) revert ExceedsMaxLoss();
            }

            strategies[strategy].currentDebt = targetDebt;
            totalDebt -= (currentDebt - targetDebt);
        }

        emit DebtUpdated(strategy, currentDebt, targetDebt);
        return targetDebt;
    }

    /**
     * @notice Process strategy report
     */
    function _processReport(address strategy) internal {
        (uint256 profit, uint256 loss) = IStrategy(strategy).report();
        
        uint256 currentDebt = strategies[strategy].currentDebt;
        strategies[strategy].lastReport = block.timestamp;
        
        // Update total debt based on profit/loss
        if (profit > 0) {
            totalDebt += profit;
        } else if (loss > 0) {
            totalDebt = totalDebt > loss ? totalDebt - loss : 0;
            strategies[strategy].currentDebt = currentDebt > loss ? currentDebt - loss : 0;
        }
        
        emit StrategyReported(strategy, profit, loss, strategies[strategy].currentDebt, 0);
    }

    /**
     * @notice Remove strategy from queue
     */
    function _removeFromQueue(address strategy) internal {
        for (uint256 i = 0; i < strategyQueue.length; ++i) {
            if (strategyQueue[i] == strategy) {
                strategyQueue[i] = strategyQueue[strategyQueue.length - 1];
                strategyQueue.pop();
                break;
            }
        }
    }

    /**
     * @notice Override for deposit to ensure minimum idle is maintained
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
        whenNotPaused
    {
        super._deposit(caller, receiver, assets, shares);
    }

    /**
     * @notice Override for withdraw to handle strategy withdrawals
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override nonReentrant whenNotPaused {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        uint256 availableAssets = totalIdle();
        
        if (availableAssets >= assets) {
            // Sufficient idle assets for withdrawal
            _burn(owner, shares);
            IERC20(asset()).safeTransfer(receiver, assets);
        } else {
            // Need to withdraw from strategies
            uint256 needed = assets - availableAssets;
            _withdrawFromStrategies(needed);
            
            _burn(owner, shares);
            IERC20(asset()).safeTransfer(receiver, assets);
        }
    }

    /**
     * @notice Withdraw assets from strategies in queue order
     */
    function _withdrawFromStrategies(uint256 needed) internal {
        for (uint256 i = 0; i < strategyQueue.length && needed > 0; ++i) {
            address strategy = strategyQueue[i];
            if (!strategies[strategy].isActive) continue;

            uint256 currentDebt = strategies[strategy].currentDebt;
            if (currentDebt == 0) continue;

            uint256 toWithdraw = Math.min(needed, currentDebt);
            uint256 withdrawn = IStrategy(strategy).freeFunds(toWithdraw);
            
            strategies[strategy].currentDebt -= Math.min(withdrawn, currentDebt);
            totalDebt -= Math.min(withdrawn, totalDebt);
            needed -= Math.min(withdrawn, needed);
        }
    }

    /**
     * @notice UUPS upgrade authorization
     */
    function _authorizeUpgrade(address newImplementation) 
        internal 
        override 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {}
}