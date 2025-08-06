pragma solidity ^0.8.23;

interface IUniswapV3 {
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }
    function collect(CollectParams memory params) external returns (uint256 amount0, uint256 amount1);
}