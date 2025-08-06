pragma solidity ^0.8.23;

struct Lot {
    uint256 id;
    address[] stakers;
    uint256[] stakes;
    uint256 shares;
    uint256 price;
    uint256 startAt;
}

struct Position {
    uint256 confirmed;
    uint256 queued;
    uint256 pending;
    uint256 consolidatedAt;
}

interface IBGM {
    event Redeem(address indexed user, uint256 amount);
	event Contribute(address indexed user, uint256 lotId, uint256 amount);
	event Delegated(bytes pubkey, address indexed delegator, uint256 amount);
	event DelegationCancelled(bytes pubkey, address indexed delegator, uint256 amount);
	event UnbondQueued(bytes pubkey, address indexed delegator, uint256 amount);
	event UnbondCancelled(bytes pubkey, address indexed delegator, uint256 amount);
	event Unbonded(bytes pubkey, address indexed delegator, uint256 amount);

  	function depositFor(address[] calldata vaults, address to) external;
	function contribute(uint256 amount) external;
	function redeem(uint256 amount) external;
	function delegate(bytes calldata validator, uint128 amount) external;
	function unbondQueue(bytes calldata validator, uint256 amount) external;
	function unbond(bytes calldata validator) external;
	function cancel(bytes calldata validator, uint128 amount) external;
	function cancelUnbond(bytes calldata validator, uint128 amount) external;
	function activate(bytes calldata pubkey) external;
	function deactivate(bytes calldata pubkey) external;

	function getBalance(address account) external view returns (uint256);
	function getOpenLot() external view returns (Lot memory);
	function getOngoingLots() external view returns (Lot[] memory);
	function maxLotSize() external view returns (uint256);
	function getDelegatedBoostBalance(bytes calldata pubkey, address owner) external view returns (Position memory);
	function getDelegatedUnboostBalance(bytes calldata pubkey, address owner) external view returns (Position memory);
}