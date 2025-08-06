// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IInfrared {
    function claimExternalVaultRewards(address _asset, address user) external;
}