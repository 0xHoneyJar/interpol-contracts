// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

/**
 * @title IHenloStaking
 * @notice Interface for HENLO staking contract
 */
interface IHenloStaking {
    function stake(uint256 amount) external;
    function unstake(uint256 amount) external;
    function claimRewards() external returns (uint256);
    function getStakedAmount(address user) external view returns (uint256);
    function getPendingRewards(address user) external view returns (uint256);
    function getRewardToken() external view returns (address);
}