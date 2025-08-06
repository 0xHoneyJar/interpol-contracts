// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20} from "solady/tokens/ERC20.sol";
import {DynamicArrayLib as DAL} from "solady/utils/DynamicArrayLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeTransferLib as STL} from "solady/utils/SafeTransferLib.sol";
import {IRelaxedERC20} from "../utils/IRelaxedERC20.sol";
import {BaseVaultAdapter} from "./BaseVaultAdapter.sol";

interface IKodiakFarm {
    function stakeLocked(uint256 liquidity, uint256 secs) external;
    function withdrawLocked(bytes32 kek_id) external;
    function getReward() external returns (uint256[] memory);
    function getAllRewardTokens() external view returns (address[] memory);
    function lock_time_for_max_multiplier() external view returns (uint256);
    function xKdk() external view returns (address);
    function kdk() external view returns (address);
    function stakingToken() external view returns (address);
    function earned(address account) external view returns (uint256[] memory);
    function xKdkPercentage() external view returns (uint256);
    function lockedLiquidityOf(address account) external view returns (uint256);
    function sync() external;
    
    event StakeLocked(
        address indexed user,
        uint256 amount,
        uint256 secs,
        bytes32 kek_id,
        address source_address
    );
    event WithdrawLocked(
        address indexed user,
        uint256 amount,
        bytes32 kek_id,
        address destination_address
    );
    event RewardPaid(
        address indexed user,
        uint256 reward,
        address token_address,
        address destination_address
    );
}

interface XKDK {
    function redeem(uint256,uint256) external;
    function finalizeRedeem(uint256) external;
    function balanceOf(address account) external view returns (uint256);
    function rewardsAddress() external view returns (address);
}

interface IKodiakRewards {
    function distributedTokensLength() external view returns (uint256);
    function distributedToken(uint256 index) external view returns (address);
    function pendingRewardsAmount(address token, address userAddress) external view returns (uint256);
    function harvestAllRewards() external;

}

contract KodiakAdapter is BaseVaultAdapter {
    using DAL for address[];
    using DAL for uint256[];
    using DAL for DAL.DynamicArray;
    /*###############################################################
                            STORAGE
    ###############################################################*/
    mapping(bytes32 kekId => uint256 amount) amounts;
    uint256 public lockTime;
    uint256[48] __gap_;
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
    function _transferRewards(address vault) internal {
        // first distribute the rewards from the farm
        IKodiakFarm kodiakFarm = IKodiakFarm(vault);
        address[] memory rewardTokens = kodiakFarm.getAllRewardTokens();
        for (uint256 i; i < rewardTokens.length; i++) {
            uint256 amount = IERC20(rewardTokens[i]).balanceOf(address(this));
            if (amount == 0) continue;
            /*
                we skip the transfer, to not block any other rewards
                it can always be retrieved later because we use the balanceOf() function
            */
            try IRelaxedERC20(rewardTokens[i]).transfer(locker, amount) {} catch {
                emit Adapter__FailedTransfer(locker, rewardTokens[i], amount);
            }
        }

        // then distribute the rewards from the KodiakRewards contract
        IKodiakRewards kodiakRewards = IKodiakRewards(XKDK(kodiakFarm.xKdk()).rewardsAddress());
        uint256 distributedTokensLength = kodiakRewards.distributedTokensLength();
        for (uint256 i; i < distributedTokensLength; i++) {
            address token = kodiakRewards.distributedToken(i);
            uint256 amount = IERC20(token).balanceOf(address(this));
            if (amount == 0) continue;
            try IRelaxedERC20(token).transfer(locker, amount) {} catch {
                emit Adapter__FailedTransfer(locker, token, amount);
            }
        }
    }
    /*###############################################################
                            EXTERNAL
    ###############################################################*/
    function stake(address vault, uint256 amount) external override onlyLocker isVaultValid(vault) returns (uint256) {
        IKodiakFarm kodiakFarm = IKodiakFarm(vault);
        address token = kodiakFarm.stakingToken();
        uint256 duration = lockTime > 0 ? lockTime : kodiakFarm.lock_time_for_max_multiplier();

        STL.safeTransferFrom(token, locker, address(this), amount);
        STL.safeApprove(token, address(kodiakFarm), amount);
        bytes32 expectedKekId = keccak256(
            abi.encodePacked(
                address(this),
                block.timestamp,
                amount,
                kodiakFarm.lockedLiquidityOf(address(this))
            )
        );
        kodiakFarm.stakeLocked(amount, duration);
        amounts[expectedKekId] = amount;
        return amount;
    }

    function unstake(address vault, uint256 kekIdAsUint) external override onlyLocker isVaultValid(vault) returns (uint256) {
        IKodiakFarm kodiakFarm = IKodiakFarm(vault);
        address token = kodiakFarm.stakingToken();

        kodiakFarm.withdrawLocked(bytes32(kekIdAsUint));
        _transferRewards(vault);
        uint256 unstakedAmount = amounts[bytes32(kekIdAsUint)];
        uint256 balance = IERC20(token).balanceOf(address(this));
        delete amounts[bytes32(kekIdAsUint)];
        STL.safeTransfer(token, locker, balance);
        return unstakedAmount;
    }

    function claim(address vault) external override onlyLocker isVaultValid(vault) returns (address[] memory, uint256[] memory) {
        IKodiakFarm kodiakFarm = IKodiakFarm(vault);
        IKodiakRewards kodiakRewards = IKodiakRewards(XKDK(kodiakFarm.xKdk()).rewardsAddress());

        (address[] memory rewardTokens, uint256[] memory amounts) = earned(vault);

        try kodiakFarm.getReward() {} catch {}
        try kodiakRewards.harvestAllRewards() {} catch {}

        _transferRewards(vault);

        return (rewardTokens, amounts);
    }

    function wildcard(address vault, uint8 func, bytes calldata args) external override onlyLocker isVaultValid(vault) {
        IKodiakFarm kodiakFarm = IKodiakFarm(vault);
        XKDK xKdk = XKDK(kodiakFarm.xKdk());
        if (func == 0) {
            (uint256 amount, uint256 duration) = abi.decode(args, (uint256, uint256));
            xKdk.redeem(amount, duration);
        } else if (func == 1) {
            (uint256 index) = abi.decode(args, (uint256));
            xKdk.finalizeRedeem(index);
            IRelaxedERC20(kodiakFarm.kdk()).transfer(locker, ERC20(kodiakFarm.kdk()).balanceOf(address(this)));
        } else if (func == 2) {
            (uint256 duration) = abi.decode(args, (uint256));
            lockTime = duration;
        }
    }
    /*###############################################################
                            VIEW
    ###############################################################*/
    function stakingToken(address vault) external view override returns (address) {
        return IKodiakFarm(vault).stakingToken();
    }

    function earned(address vault) public view override returns (address[] memory, uint256[] memory) {
        IKodiakFarm kodiakFarm = IKodiakFarm(vault);
        DAL.DynamicArray memory rewardTokens = kodiakFarm.getAllRewardTokens().wrap();
        DAL.DynamicArray memory amounts = kodiakFarm.earned(address(this)).wrap();
        {
            address kdk = kodiakFarm.kdk();
            uint256 xKDKAmount;
            /*
                To have an accurate result, we must reproduce the logic of the rewards payout
                meaning that a chunk of kdk goes as xKDK
            */
            for (uint256 i; i < rewardTokens.length(); i++) {
                if (rewardTokens.getAddress(i) == kdk) {
                    uint256 amount = amounts.getUint256(i);
                    xKDKAmount = amount * kodiakFarm.xKdkPercentage() / 100e18;
                    amounts.set(i, amount - xKDKAmount);
                }
            }
            rewardTokens.p(kodiakFarm.xKdk());
            amounts.p(xKDKAmount);
        }
        {
            IKodiakRewards kodiakRewards = IKodiakRewards(XKDK(kodiakFarm.xKdk()).rewardsAddress());
            // also include the rewards from the KodiakRewards contract
            uint256 previousLength = rewardTokens.length();
            rewardTokens.expand(rewardTokens.length() + kodiakRewards.distributedTokensLength());
            amounts.expand(rewardTokens.length());
            for (uint256 i; i < kodiakRewards.distributedTokensLength(); i++) {
                rewardTokens.set(i + previousLength, kodiakRewards.distributedToken(i));
                amounts.set(i + previousLength, kodiakRewards.pendingRewardsAmount(kodiakRewards.distributedToken(i), address(this)));
            }

        }
        return (rewardTokens.asAddressArray(), amounts.asUint256Array());
    }

    function version() external pure override returns (string memory) {
        return "1.0";
    }
}

