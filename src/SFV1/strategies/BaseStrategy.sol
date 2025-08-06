// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import {BaseStrategy as YearnBaseStrategy} from "../../../lib/tokenized-strategy/src/BaseStrategy.sol";
import {ITokenizedStrategy} from "../../../lib/tokenized-strategy/src/interfaces/ITokenizedStrategy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IStrategy} from "../interfaces/IStrategy.sol";
import {IHaikuAdapter} from "../interfaces/IHaikuAdapter.sol";

/**
 * @title BaseStrategy
 * @author Set & Forgetti
 * @notice Base strategy contract implementing both Yearn's TokenizedStrategy pattern and our IStrategy interface
 * @dev Provides common functionality for all Set & Forgetti strategies on Berachain
 */
abstract contract BaseStrategy is 
    YearnBaseStrategy,
    UUPSUpgradeable,
    AccessControlUpgradeable, 
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Role for vault that can call strategy functions
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");
    
    /// @notice Role for keepers who can call harvest and tend functions
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    
    /// @notice Maximum basis points (100%)
    uint256 public constant MAX_BPS = 10_000;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Address of the vault that owns this strategy
    address public vault;
    

    
    // Note: Yearn's BaseStrategy provides totalAssets(), asset(), etc.
    // We add our additional storage variables here
    
    /// @notice Haiku adapter for auto-compounding
    address public haikuAdapter;
    
    /// @notice Performance fee in basis points
    uint256 public performanceFee;
    
    /// @notice Management fee in basis points (annual)
    uint256 public managementFee;
    
    /// @notice Last harvest timestamp
    uint256 public lastHarvest;
    


    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event VaultUpdated(address indexed oldVault, address indexed newVault);
    event MaxDebtUpdated(uint256 oldMaxDebt, uint256 newMaxDebt);
    event HaikuAdapterUpdated(address indexed oldAdapter, address indexed newAdapter);
    event EmergencyShutdownActivated();
    event EmergencyShutdownDeactivated();
    event HarvestExecuted(uint256 profit, uint256 loss, uint256 totalAssets);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error OnlyVault();
    error DebtExceedsMax();
    error ZeroAddress();
    error UnauthorizedCaller();
    error StrategyShutdown();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Ensures only the vault can call function
    modifier onlyVault() {
        if (msg.sender != vault && !hasRole(VAULT_ROLE, msg.sender)) {
            revert OnlyVault();
        }
        _;
    }

    /// @notice Ensures only keeper or management can call function
    modifier onlyKeeper() {
        if (!hasRole(KEEPER_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert UnauthorizedCaller();
        }
        _;
    }

    /// @notice Ensures strategy is not in emergency shutdown
    modifier notShutdown() {
        // Check if Yearn's strategy is shutdown
        // We can add our own emergency shutdown flag if needed
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Constructor for BaseStrategy
     * @param _asset The underlying asset for the strategy
     * @param _name The name of the strategy
     */
    constructor(address _asset, string memory _name) YearnBaseStrategy(_asset, _name) {
        // Yearn's constructor handles the asset and tokenized strategy setup
    }

    function __BaseStrategy_init(
        address vault_,
        address management_,
        address keeper_
    ) internal onlyInitializing {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        vault = vault_;
        performanceFee = 2000; // 20% default
        managementFee = 200; // 2% annual default
        
        _grantRole(DEFAULT_ADMIN_ROLE, management_);
        _grantRole(VAULT_ROLE, vault_);
        _grantRole(KEEPER_ROLE, keeper_);
    }

    /*//////////////////////////////////////////////////////////////
                            STRATEGY FUNCTIONS
    //////////////////////////////////////////////////////////////*/



    /*//////////////////////////////////////////////////////////////
                            HAIKU INTEGRATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Auto-compound using Haiku calldata
     * @param haikuPayload Signed calldata from Haiku API
     * @param minAmountOut Minimum expected output for slippage protection
     */
    function compoundWithHaiku(
        bytes calldata haikuPayload,
        uint256 minAmountOut
    ) external onlyKeeper nonReentrant notShutdown {
        if (haikuAdapter == address(0)) revert ZeroAddress();
        
        // Execute Haiku calldata through adapter
        uint256 amountOut = IHaikuAdapter(haikuAdapter).executeHaikuCalldata(haikuPayload, minAmountOut);
        
        // Process any additional compounding logic
        _afterHaikuCompound(amountOut);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/





    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set vault address
     * @param newVault New vault address
     */
    function setVault(address newVault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newVault == address(0)) revert ZeroAddress();
        address oldVault = vault;
        vault = newVault;
        
        _revokeRole(VAULT_ROLE, oldVault);
        _grantRole(VAULT_ROLE, newVault);
        
        emit VaultUpdated(oldVault, newVault);
    }



    /**
     * @notice Set Haiku adapter address
     * @param newAdapter Address of the new Haiku adapter
     */
    function setHaikuAdapter(address newAdapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address oldAdapter = haikuAdapter;
        haikuAdapter = newAdapter;
        emit HaikuAdapterUpdated(oldAdapter, newAdapter);
    }

    // Note: Use Yearn's shutdown mechanisms instead of custom emergency shutdown

    /**
     * @notice Pause the strategy
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the strategy
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                        ABSTRACT FUNCTIONS TO IMPLEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Deploy assets to the underlying protocol
     * @param _amount Amount of assets to deploy
     */
    function _deployFunds(uint256 _amount) internal virtual override;

    /**
     * @dev Free assets from the underlying protocol
     * @param _amount Amount of assets to free
     */
    function _freeFunds(uint256 _amount) internal virtual override;

    /**
     * @dev Harvest and report strategy performance
     * @return _totalAssets Total assets after harvest
     */
    function _harvestAndReport() internal virtual override returns (uint256 _totalAssets);

    /**
     * @dev Check if strategy should be tended
     * @return Should return true if tend() should be called by keeper
     */
    function _tendTrigger() internal view virtual override returns (bool) {
        return false;
    }

    /**
     * @dev Perform strategy maintenance (optional override)
     * @param _totalIdle Total idle assets that are available to deploy
     */
    function _tend(uint256 _totalIdle) internal virtual override {
        // Default implementation does nothing
    }

    /**
     * @dev Emergency withdraw implementation
     * @param amount Amount to withdraw
     */
    function _emergencyWithdraw(uint256 amount) internal override {
        _freeFunds(amount);
    }

    /**
     * @dev Called after Haiku compound execution (optional override)
     * @param amountOut Amount received from Haiku operation
     */
    function _afterHaikuCompound(uint256 amountOut) internal virtual {
        // Default implementation does nothing
    }




    /*//////////////////////////////////////////////////////////////
                            UUPS UPGRADE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice UUPS upgrade authorization
     */
    function _authorizeUpgrade(address newImplementation) 
        internal 
        override 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {}
}