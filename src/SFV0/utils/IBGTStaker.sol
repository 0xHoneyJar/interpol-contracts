pragma solidity ^0.8.23;

interface IBGTStaker {
    function getReward() external;
    function rewards(address account) external view returns (uint256);
    function earned(address account) external view returns (uint256);
    function rewardToken() external view returns (address);
}