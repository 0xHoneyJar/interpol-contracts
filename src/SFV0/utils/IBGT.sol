pragma solidity ^0.8.23;

interface IBGT {
    event QueueBoost(address indexed sender, bytes indexed pubkey, uint128 amount);
    event CancelBoost(address indexed sender, bytes indexed pubkey, uint128 amount);
    event ActivateBoost(address indexed sender, address indexed user, bytes indexed pubkey, uint128 amount);
    event QueueDropBoost(address indexed user, bytes indexed pubkey, uint128 amount);
    event CancelDropBoost(address indexed user, bytes indexed pubkey, uint128 amount);
    event DropBoost(address indexed sender, address indexed user, bytes indexed pubkey, uint128 amount);
    event Redeem(address indexed from, address indexed receiver, uint256 amount);
    
    function redeem(address receiver, uint256 amount) external;
    function queueBoost(bytes calldata pubkey, uint128 amount) external;
    function cancelBoost(bytes calldata pubkey, uint128 amount) external;
    function activateBoost(address user, bytes calldata pubkey) external returns (bool);
    function queueDropBoost(bytes calldata pubkey, uint128 amount) external;
    function cancelDropBoost(bytes calldata pubkey, uint128 amount) external;
    function dropBoost(address user, bytes calldata pubkey) external returns (bool);
    function delegate(address delegatee) external;

    function balanceOf(address account) external view returns (uint256);
    function unboostedBalanceOf(address account) external view returns (uint256);
    function boostedQueue(address account, bytes calldata pubkey) external view returns (uint32 blockNumberLast, uint128 balance);
    function queuedBoost(address account) external view returns (uint128);
    function boosted(address account, bytes calldata pubkey) external view returns (uint128);
    function boosts(address account) external view returns (uint128);
    function boostees(bytes calldata pubkey) external view returns (uint128);
    function totalBoosts() external view returns (uint128);
    function normalizedBoost(bytes calldata pubkey) external view returns (uint256);
    function staker() external view returns (address);
    function activateBoostDelay() external view returns (uint32);
    function dropBoostDelay() external view returns (uint32);
}