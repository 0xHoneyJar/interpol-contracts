// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

/**
 * @title IHaikuAdapter
 * @author Set & Forgetti
 * @notice Interface for Haiku adapter that validates and executes signed calldata
 *         for auto-compounding yields on Berachain
 */
interface IHaikuAdapter {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when Haiku calldata is successfully executed
    event HaikuCallExecuted(
        address indexed vault,
        address indexed strategy,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 calldataHash
    );

    /// @notice Emitted when Haiku router address is updated
    event HaikuRouterUpdated(address indexed oldRouter, address indexed newRouter);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidCalldata();
    error InvalidSignature();
    error CalldataExpired();
    error UnauthorizedRouter();
    error SlippageTooHigh();
    error InsufficientOutput();

    /*//////////////////////////////////////////////////////////////
                            CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Execute Haiku calldata for auto-compounding
     * @param payload Signed calldata payload from Haiku API
     * @param minAmountOut Minimum expected output amount for slippage protection
     * @return amountOut Actual amount received from the operation
     * @dev Should validate signature, expiry, and slippage before execution
     */
    function executeHaikuCalldata(
        bytes calldata payload,
        uint256 minAmountOut
    ) external returns (uint256 amountOut);

    /**
     * @notice Validate Haiku calldata without executing
     * @param payload Signed calldata payload to validate
     * @return isValid Whether the calldata is valid
     * @return expectedOutput Expected output amount
     */
    function validateHaikuCalldata(
        bytes calldata payload
    ) external view returns (bool isValid, uint256 expectedOutput);

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get the Haiku router address
     * @return router Address of the Haiku router
     */
    function haikuRouter() external view returns (address router);

    /**
     * @notice Get the maximum allowed slippage basis points
     * @return slippage Maximum slippage in basis points (e.g., 100 = 1%)
     */
    function maxSlippage() external view returns (uint256 slippage);

    /**
     * @notice Get the maximum calldata age in seconds
     * @return maxAge Maximum age before calldata expires
     */
    function maxCalldataAge() external view returns (uint256 maxAge);

    /**
     * @notice Check if a vault is authorized to use this adapter
     * @param vault Address of the vault to check
     * @return authorized Whether the vault is authorized
     */
    function isAuthorizedVault(address vault) external view returns (bool authorized);
}