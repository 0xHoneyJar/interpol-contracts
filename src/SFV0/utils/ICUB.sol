// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface ICUB {
    function badgesHeld(address user) external view returns (uint256);
    function badgesPercentageOfUser(address _user) external view returns (uint256);
}