// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeTransferLib as STL} from "solady/utils/SafeTransferLib.sol";

import {IRelaxedERC20} from "../utils/IRelaxedERC20.sol";
import {BaseVaultAdapter} from "./BaseVaultAdapter.sol";

interface IBeradromePlugin {
    function depositFor(address account, uint256 amount) external;
    function withdrawTo(address account, uint256 amount) external;
    function getGauge() external view returns (address);
    function getToken() external view returns (address);
}

interface IBeradromeGauge {
    function getReward(address account) external;
    function getRewardTokens() external view returns (address[] memory);
    function earned(address account, address _rewardsToken) external view returns (uint256);
}

contract BeradromeAdapter is BaseVaultAdapter {
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
                            EXTERNAL
    ###############################################################*/
    function stake(address vault, uint256 amount) external override onlyLocker isVaultValid(vault) returns (uint256) {
        IBeradromePlugin beradromePlugin = IBeradromePlugin(vault);
        address token = beradromePlugin.getToken();
        STL.safeTransferFrom(token, locker, address(this), amount);
        STL.safeApprove(token, address(beradromePlugin), amount);
        beradromePlugin.depositFor(address(this), amount);
        return amount;
    }

    function unstake(address vault, uint256 amount) external override onlyLocker isVaultValid(vault) returns (uint256) {
        IBeradromePlugin beradromePlugin = IBeradromePlugin(vault);
        address token = beradromePlugin.getToken();
        beradromePlugin.withdrawTo(address(this), amount);
        STL.safeTransfer(token, locker, amount);
        return amount;
    }

    function claim(address vault) external override onlyLocker isVaultValid(vault) returns (address[] memory, uint256[] memory) {
        IBeradromePlugin beradromePlugin = IBeradromePlugin(vault);
        IBeradromeGauge gauge = IBeradromeGauge(beradromePlugin.getGauge());
        address[] memory rewardTokens = gauge.getRewardTokens();
        uint256[] memory amounts = new uint256[](rewardTokens.length);
        gauge.getReward(address(this));
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
        return IBeradromePlugin(vault).getToken();
    }
    
    function earned(address vault) public view override returns (address[] memory, uint256[] memory) {
        IBeradromePlugin beradromePlugin = IBeradromePlugin(vault);
        IBeradromeGauge gauge = IBeradromeGauge(beradromePlugin.getGauge());
        address[] memory rewardTokens = gauge.getRewardTokens();
        uint256[] memory amounts = new uint256[](rewardTokens.length);
        for (uint256 i; i < rewardTokens.length; i++) {
            amounts[i] = gauge.earned(address(this), rewardTokens[i]);
        }
        return (rewardTokens, amounts);
    }

    function version() external pure override returns (string memory) {
        return "1.0";
    }
}
