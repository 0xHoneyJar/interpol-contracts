// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Ownable} from "solady/auth/Ownable.sol";

import {HoneyLocker} from "./HoneyLocker.sol";

contract LockerFactory is Ownable {
    /*###############################################################
                            EVENTS
    ###############################################################*/
    event LockerFactory__NewLocker(address indexed owner, address locker, address referrer, bool unlocked);
    /*###############################################################
                            STORAGE
    ###############################################################*/
    address internal immutable  HONEY_QUEEN;
    address public              beacon;
    /*###############################################################
                            CONSTRUCTOR
    ###############################################################*/
    constructor(address _honeyQueen, address _owner) {
        HONEY_QUEEN = _honeyQueen;
        _initializeOwner(_owner);
    }
    /*###############################################################
                            OWNER
    ###############################################################*/
    function setBeacon(address _beacon) external onlyOwner {
        beacon = _beacon;
    }
    /*###############################################################
                            EXTERNAL
    ###############################################################*/
    /// @notice                 Creates a new HoneyLocker contract
    /// @dev                    This function deploys a new HoneyLocker contract and initializes it with the provided parameters
    /// @param _owner           The address that will own the new HoneyLocker
    /// @param _referral        The address of the referrer for this locker
    /// @param _unlocked        Whether the locker is unlocked or not
    /// @return HoneyLocker     The newly created and initialized HoneyLocker contract
    /// @custom:emits           NewLocker event with the owner's address and the new locker's address
    function createLocker(
        address _owner,
        address _referral,
        bool _unlocked
    ) external returns (address payable) {
        bytes memory data = abi.encodeWithSelector(HoneyLocker.initialize.selector, HONEY_QUEEN, _owner, _referral, _unlocked);
        address locker = address(new BeaconProxy(beacon, data));

        emit LockerFactory__NewLocker(_owner, locker, _referral, _unlocked);
        return payable(locker);
    }
}