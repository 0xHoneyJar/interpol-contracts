// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {SafeTransferLib as STL} from "solady/utils/SafeTransferLib.sol";

import {HoneyQueen} from "../HoneyQueen.sol";
import {TokenReceiver} from "../utils/TokenReceiver.sol";

abstract contract BaseVaultAdapter is Initializable, TokenReceiver {
    /*###############################################################
                            ERRORS
    ###############################################################*/
    error BaseVaultAdapter__AlreadyInitialized();
    error BaseVaultAdapter__NotAuthorized();
    error BaseVaultAdapter__NotImplemented();
    error BaseVaultAdapter__NotAuthorizedUpgrade();
    error BaseVaultAdapter__InvalidVault();
    /*###############################################################
                            EVENTS
    ###############################################################*/
    event Adapter__FailedTransfer(address indexed locker, address indexed token, uint256 amount);
    event Adapter__Upgraded(address indexed from, address indexed to);
    /*###############################################################
                            STORAGE
    ###############################################################*/
    address     public              locker;
    address     internal            honeyQueen;
    address     internal            adapterBeacon;

    uint256[47] __gap;
    /*###############################################################
                            MODIFIERS
    ###############################################################*/
    modifier onlyLocker() {
        if (msg.sender != locker) revert BaseVaultAdapter__NotAuthorized();
        _;
    }
    modifier isVaultValid(address vault) {
        if (!HoneyQueen(honeyQueen).isVaultValidForAdapterBeacon(adapterBeacon, vault)) revert BaseVaultAdapter__InvalidVault();
        _;
    }
    /*###############################################################
                            EXTERNAL
    ###############################################################*/
    function initialize(address locker, address _honeyQueen, address _adapterBeacon) external virtual;
    function stake(address vault, uint256 amount) external virtual returns (uint256);
    function unstake(address vault, uint256 amount) external virtual returns (uint256);
    function claim(address vault) external virtual returns (address[] memory rewardTokens, uint256[] memory earned);
    function wildcard(address vault, uint8 func, bytes calldata args) external virtual;
    
    function rescueERC20(address token) external virtual {
        STL.safeTransferAll(token, locker);
    }
    /*###############################################################
                            PROXY LOGIC
    ###############################################################*/
    /*###############################################################
                            VIEW/PURE
    ###############################################################*/
    function stakingToken(address vault) external view virtual returns (address);
    function earned(address vault) public view virtual returns (address[] memory rewardTokens, uint256[] memory amounts);
    function version() external pure virtual returns (string memory);
    function implementation() external view returns (address) {
        return IBeacon(adapterBeacon).implementation();
    }
}

