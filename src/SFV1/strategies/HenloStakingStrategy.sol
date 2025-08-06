// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaseStrategy} from "./BaseStrategy.sol";
import {IHenloStaking} from "../interfaces/IHenloStaking.sol";

/**
 * @title HenloStakingStrategy
 * @author Set & Forgetti
 * @notice Strategy for staking HENLO tokens to earn rewards
 * @dev Implements staking mechanism for HENLO with auto-compounding via Haiku
 */
contract HenloStakingStrategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice HENLO staking contract address
    address public stakingContract;
    
    /// @notice Reward token address (could be HENLO itself or another token)
    address public rewardToken;
    
    /// @notice Minimum amount needed to trigger harvest
    uint256 public minHarvestAmount;
    
    /// @notice Last known staked amount
    uint256 public stakedAmount;
    
    /// @notice Accumulated rewards since last harvest
    uint256 public accumulatedRewards;
    
    /// @notice Harvest frequency in seconds
    uint256 public harvestFrequency;
    
    /// @notice Last harvest timestamp
    uint256 public lastHarvestTime;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Staked(uint256 amount);
    event Unstaked(uint256 amount);
    event RewardsClaimed(uint256 amount);
    event HarvestParametersUpdated(uint256 minAmount, uint256 frequency);
    event StakingContractUpdated(address indexed oldContract, address indexed newContract);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error StakingContractNotSet();
    error InsufficientStakedAmount();
    error HarvestTooEarly();



    /*//////////////////////////////////////////////////////////////
                               INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the HenloStakingStrategy
     * @param henloToken The HENLO token address
     * @param stakingContract_ The staking contract address
     * @param vault_ The vault address
     * @param management_ The management address
     * @param keeper_ The keeper address
     */
    function initialize(
        address henloToken,
        address stakingContract_,
        address vault_,
        address management_,
        address keeper_
    ) external initializer {
        __BaseStrategy_init(
            henloToken,
            "HENLO Staking Strategy",
            vault_,
            management_,
            keeper_
        );

        stakingContract = stakingContract_;
        rewardToken = IHenloStaking(stakingContract_).getRewardToken();
        minHarvestAmount = 1e18; // 1 HENLO minimum for harvest
        harvestFrequency = 8 hours; // Harvest every 8 hours
        lastHarvestTime = block.timestamp;

        // Approve staking contract to spend HENLO
        IERC20(henloToken).safeApprove(stakingContract_, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                        STRATEGY IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Deploy assets to HENLO staking
     * @param assets Amount of HENLO to stake
     */
    function _deployFunds(uint256 assets) internal override {
        if (stakingContract == address(0)) revert StakingContractNotSet();
        
        // Stake HENLO tokens
        IHenloStaking(stakingContract).stake(assets);
        stakedAmount += assets;
        
        emit Staked(assets);
    }

    /**
     * @dev Free assets from HENLO staking
     * @param amount Amount of HENLO to unstake
     * @return actualAmount Actual amount unstaked
     */
    function _freeFunds(uint256 amount) internal override returns (uint256 actualAmount) {
        if (stakingContract == address(0)) revert StakingContractNotSet();
        
        uint256 availableToUnstake = stakedAmount;
        actualAmount = Math.min(amount, availableToUnstake);
        
        if (actualAmount == 0) return 0;
        
        // Unstake HENLO tokens
        IHenloStaking(stakingContract).unstake(actualAmount);
        stakedAmount -= actualAmount;
        
        emit Unstaked(actualAmount);
        return actualAmount;
    }

    /**
     * @dev Harvest rewards and report performance
     * @return profit Amount of profit generated
     * @return loss Amount of loss incurred
     */
    function _harvestAndReport() internal override returns (uint256 profit, uint256 loss) {
        if (stakingContract == address(0)) return (0, 0);
        
        uint256 assetsBefore = totalAssets();
        
        // Claim rewards from staking
        uint256 rewardsClaimed = IHenloStaking(stakingContract).claimRewards();
        
        if (rewardsClaimed > 0) {
            accumulatedRewards += rewardsClaimed;
            emit RewardsClaimed(rewardsClaimed);
            
            // If reward token is different from asset, need to swap
            if (rewardToken != asset()) {
                // This would integrate with Haiku for optimal swapping
                // For now, assume rewards are in HENLO
            }
        }
        
        uint256 assetsAfter = totalAssets();
        
        if (assetsAfter > assetsBefore) {
            profit = assetsAfter - assetsBefore;
        } else if (assetsAfter < assetsBefore) {
            loss = assetsBefore - assetsAfter;
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
     * @dev Perform strategy maintenance (compound rewards)
     * @param totalIdle Total idle assets in vault
     */
    function _tendThis(uint256 totalIdle) internal override {
        // Claim and compound rewards
        _harvestAndReport();
    }

    /**
     * @dev Called after Haiku compound execution
     * @param amountOut Amount received from Haiku operation
     */
    function _afterHaikuCompound(uint256 amountOut) internal override {
        // If we received HENLO from swapping rewards, stake it
        if (amountOut > 0) {
            _deployFunds(amountOut);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get total assets under management
     * @return Total HENLO assets (staked + idle)
     */
    function totalAssets() public view override returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        return idle + stakedAmount;
    }

    /**
     * @notice Get pending rewards from staking
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
        uint256 stakedAmount_,
        uint256 idleAssets_,
        uint256 pendingRewards_,
        uint256 lastHarvest_,
        uint256 nextHarvest_,
        bool canHarvest_
    ) {
        totalAssets_ = totalAssets();
        stakedAmount_ = stakedAmount;
        idleAssets_ = IERC20(asset()).balanceOf(address(this));
        pendingRewards_ = _getPendingRewards();
        lastHarvest_ = lastHarvestTime;
        nextHarvest_ = lastHarvestTime + harvestFrequency;
        canHarvest_ = block.timestamp >= nextHarvest_ && pendingRewards_ >= minHarvestAmount;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Get pending rewards from staking contract
     * @return Pending reward amount
     */
    function _getPendingRewards() internal view returns (uint256) {
        if (stakingContract == address(0)) return 0;
        
        try IHenloStaking(stakingContract).getPendingRewards(address(this)) returns (uint256 pending) {
            return pending;
        } catch {
            return 0;
        }
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Update staking contract address
     * @param newStakingContract New staking contract address
     */
    function setStakingContract(address newStakingContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newStakingContract == address(0)) revert ZeroAddress();
        
        // If there was a previous staking contract, unstake everything
        if (stakingContract != address(0) && stakedAmount > 0) {
            IHenloStaking(stakingContract).unstake(stakedAmount);
        }
        
        address oldContract = stakingContract;
        stakingContract = newStakingContract;
        rewardToken = IHenloStaking(newStakingContract).getRewardToken();
        
        // Approve new staking contract
        IERC20(asset()).safeApprove(newStakingContract, type(uint256).max);
        
        // Re-stake everything if we have assets
        uint256 toStake = IERC20(asset()).balanceOf(address(this));
        if (toStake > 0) {
            IHenloStaking(stakingContract).stake(toStake);
            stakedAmount = toStake;
        }
        
        emit StakingContractUpdated(oldContract, newStakingContract);
    }

    /**
     * @notice Update harvest parameters
     * @param newMinAmount New minimum harvest amount
     * @param newFrequency New harvest frequency
     */
    function setHarvestParameters(uint256 newMinAmount, uint256 newFrequency) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        require(newFrequency >= 1 hours && newFrequency <= 7 days, "Invalid frequency");
        
        minHarvestAmount = newMinAmount;
        harvestFrequency = newFrequency;
        
        emit HarvestParametersUpdated(newMinAmount, newFrequency);
    }

    /*//////////////////////////////////////////////////////////////
                           EMERGENCY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emergency unstake all assets
     * @dev Only callable by admin in emergency situations
     */
    function emergencyUnstakeAll() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (stakingContract != address(0) && stakedAmount > 0) {
            IHenloStaking(stakingContract).unstake(stakedAmount);
            stakedAmount = 0;
        }
    }

    /**
     * @notice Emergency claim all rewards
     * @dev Only callable by admin in emergency situations
     */
    function emergencyClaimRewards() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (stakingContract != address(0)) {
            uint256 claimed = IHenloStaking(stakingContract).claimRewards();
            if (claimed > 0) {
                accumulatedRewards += claimed;
                emit RewardsClaimed(claimed);
            }
        }
    }
}