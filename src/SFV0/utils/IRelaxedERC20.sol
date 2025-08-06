pragma solidity ^0.8.23;

interface IRelaxedERC20 {
    function transfer(address to, uint256 value) external;
    function approve(address spender, uint256 value) external;
    function transferFrom(address from, address to, uint256 value) external;
}