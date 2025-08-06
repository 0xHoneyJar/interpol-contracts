// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title IStrategy
 * @author Set & Forgetti
 * @notice Interface for strategies that can be used by Set & Forgetti vaults.
 *         Strategies can be either ERC-4626 compliant or use Yearn's TokenizedStrategy pattern.
 */
interface IStrategy is IERC4626 {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when strategy reports profit/loss to the vault
    event StrategyReported(
        uint256 profit,
        uint256 loss,
        uint256 totalAssets,
        uint256 totalDebt
    );

    /// @notice Emitted when funds are deployed to the strategy
    event FundsDeployed(uint256 amount);

    /// @notice Emitted when funds are freed from the strategy
    event FundsFreed(uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error InsufficientAssets();
    error UnauthorizedCaller();
    error StrategyShutdown();

    /*//////////////////////////////////////////////////////////////
                            STRATEGY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploy assets to the underlying protocol
     * @param assets Amount of assets to deploy
     * @dev Should be called by the vault when allocating funds
     */
    function deployFunds(uint256 assets) external;

    /**
     * @notice Free assets from the underlying protocol
     * @param amount Amount of assets to free
     * @return actualAmount Actual amount of assets freed
     * @dev Should be called by the vault when deallocating funds
     */
    function freeFunds(uint256 amount) external returns (uint256 actualAmount);

    /**
     * @notice Report strategy performance and harvest any rewards
     * @return profit Amount of profit generated since last report
     * @return loss Amount of loss incurred since last report
     * @dev Should be called periodically to compound yields and report performance
     */
    function report() external returns (uint256 profit, uint256 loss);

    /**
     * @notice Check if strategy should be tended (maintained)
     * @return shouldTend Whether the strategy needs tending
     * @return data Optional calldata for tending
     */
    function tendTrigger() external view returns (bool shouldTend, bytes memory data);

    /**
     * @notice Perform strategy maintenance
     * @param totalIdle Total idle assets in the vault
     * @dev Called when tendTrigger returns true
     */
    function tend(uint256 totalIdle) external;

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get the vault that owns this strategy
     * @return vault Address of the owning vault
     */
    function vault() external view returns (address vault);

    /**
     * @notice Check if strategy is active
     * @return active Whether the strategy is active
     */
    function isActive() external view returns (bool active);

    /**
     * @notice Get strategy's current debt to the vault
     * @return debt Current debt amount
     */
    function currentDebt() external view returns (uint256 debt);

    /**
     * @notice Get maximum debt the strategy can handle
     * @return maxDebt Maximum debt amount
     */
    function maxDebt() external view returns (uint256 maxDebt);

    /**
     * @notice Get available deposit limit for the strategy
     * @param owner Address to check deposit limit for
     * @return limit Available deposit limit
     */
    function availableDepositLimit(address owner) external view returns (uint256 limit);

    /**
     * @notice Get available withdraw limit for the strategy
     * @param owner Address to check withdraw limit for
     * @return limit Available withdraw limit
     */
    function availableWithdrawLimit(address owner) external view returns (uint256 limit);

    /**
     * @notice Emergency function to withdraw all assets
     * @param amount Amount to withdraw in emergency
     * @return actualAmount Actual amount withdrawn
     */
    function emergencyWithdraw(uint256 amount) external returns (uint256 actualAmount);
}