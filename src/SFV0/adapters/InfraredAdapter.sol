
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC721} from "solady/tokens/ERC721.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {DynamicArrayLib as DAL} from "solady/utils/DynamicArrayLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeTransferLib as STL} from "solady/utils/SafeTransferLib.sol";
import {IRelaxedERC20} from "../utils/IRelaxedERC20.sol";
import {BaseVaultAdapter} from "./BaseVaultAdapter.sol";

interface IInfraredVault {
    struct UserReward {
        address token;
        uint256 amount;
    }

    event Staked(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event RewardPaid(address indexed account, address indexed rewardsToken, uint256 reward);

    function stake(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function getReward() external;
    function rewardTokens(uint256 index) external view returns (address);
    function earned(address account, address rewardToken) external view returns (uint256);
    function stakingToken() external view returns (address);
    function getAllRewardTokens() external view returns (address[] memory);
    function getAllRewardsForUser(address _user) external view returns (UserReward[] memory);
}

contract InfraredAdapter is BaseVaultAdapter {
    using DAL for address[];
    using DAL for uint256[];
    /*###############################################################
                            STORAGE
    ###############################################################*/
    uint256[50] __gap_;
    /*###############################################################
                            CONSTRUCTOR
    ###############################################################*/
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    /*###############################################################
                            INITIALIZATION
    ###############################################################*/
    function initialize(
        address _locker,
        address _honeyQueen,
        address _adapterBeacon
    ) external override initializer {
        locker = _locker;
        honeyQueen = _honeyQueen;
        adapterBeacon = _adapterBeacon;
    }
    /*###############################################################
                            INTERNAL
    ###############################################################*/
    /*###############################################################
                            EXTERNAL
    ###############################################################*/
    function stake(address vault, uint256 amount) external override onlyLocker isVaultValid(vault) returns (uint256) {
        IInfraredVault infraredVault = IInfraredVault(vault);
        address token = infraredVault.stakingToken();

        STL.safeTransferFrom(token, msg.sender, address(this), amount);
        STL.safeApprove(token, vault, amount);

        IInfraredVault(vault).stake(amount);
        return amount;
    }

    function unstake(address vault, uint256 amount) external override onlyLocker isVaultValid(vault) returns (uint256) {
        IInfraredVault infraredVault = IInfraredVault(vault);
        address token = infraredVault.stakingToken();

        infraredVault.withdraw(amount);
        STL.safeTransfer(token, locker, amount);
        return amount;
    }

    function claim(address vault) external override onlyLocker isVaultValid(vault) returns (address[] memory, uint256[] memory) {
        IInfraredVault infraredVault = IInfraredVault(vault);

        (address[] memory rewardTokens, uint256[] memory amounts) = earned(vault);
        infraredVault.getReward();
        for (uint256 i; i < rewardTokens.length; i++) {
            amounts[i] = IERC20(rewardTokens[i]).balanceOf(address(this));
            /*
                we skip the transfer, to not block any other rewards
                it can always be retrieved later because we use the balanceOf() function
            */
            try IRelaxedERC20(rewardTokens[i]).transfer(locker, amounts[i]) {} catch {
                emit Adapter__FailedTransfer(locker, rewardTokens[i], amounts[i]);
                amounts[i] = 0;
            }
        }
        return (rewardTokens, amounts);
    }

    function wildcard(address vault, uint8 func, bytes calldata args) external override onlyLocker isVaultValid(vault) {
        revert BaseVaultAdapter__NotImplemented();
    }
    /*###############################################################
                            VIEW
    ###############################################################*/
    function stakingToken(address vault) external view override returns (address) {
        return IInfraredVault(vault).stakingToken();
    }

    function earned(address vault) public view override returns (address[] memory, uint256[] memory) {
        IInfraredVault.UserReward[] memory rewards = IInfraredVault(vault).getAllRewardsForUser(address(this));
        address[] memory rewardTokens = new address[](rewards.length);
        uint256[] memory amounts = new uint256[](rewards.length);
        for (uint256 i; i < rewards.length; i++) {
            rewardTokens[i] = rewards[i].token;
            amounts[i] = rewards[i].amount;
        }
        return (rewardTokens, amounts);
    }

    function version() external pure override returns (string memory) {
        return "1.0";
    }
}

