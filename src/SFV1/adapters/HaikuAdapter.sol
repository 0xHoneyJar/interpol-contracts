// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IHaikuAdapter} from "../interfaces/IHaikuAdapter.sol";

/**
 * @title HaikuAdapter
 * @author Set & Forgetti
 * @notice Adapter contract for validating and executing signed Haiku calldata
 *         Provides secure interface for auto-compounding through Berachain's Haiku router
 */
contract HaikuAdapter is 
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    IHaikuAdapter 
{
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Role for vault managers who can authorize vaults
    bytes32 public constant VAULT_MANAGER_ROLE = keccak256("VAULT_MANAGER_ROLE");
    
    /// @notice Role for keepers who can execute calldata
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    
    /// @notice Maximum basis points (100%)
    uint256 public constant MAX_BPS = 10_000;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Address of the Haiku router contract
    address public haikuRouter;
    
    /// @notice Maximum allowed slippage in basis points (e.g., 100 = 1%)
    uint256 public maxSlippage;
    
    /// @notice Maximum age of calldata in seconds before it expires
    uint256 public maxCalldataAge;
    
    /// @notice Address authorized to sign Haiku calldata
    address public haikuSigner;
    
    /// @notice Mapping of vault addresses that are authorized to use this adapter
    mapping(address => bool) public authorizedVaults;
    
    /// @notice Mapping to track used calldata hashes to prevent replay attacks
    mapping(bytes32 => bool) public usedCalldataHashes;

    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Structure for decoded Haiku calldata payload
    struct HaikuPayload {
        address tokenIn;        // Input token address
        address tokenOut;       // Output token address
        uint256 amountIn;       // Input amount
        uint256 amountOutMin;   // Minimum output amount
        address recipient;      // Recipient of output tokens
        uint256 deadline;       // Deadline timestamp
        bytes routerCalldata;   // Calldata for Haiku router
        bytes signature;        // Signature from Haiku API
    }

    /*//////////////////////////////////////////////////////////////
                               INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the HaikuAdapter
     * @param admin_ The admin address
     * @param haikuRouter_ The Haiku router address
     * @param haikuSigner_ The address authorized to sign calldata
     */
    function initialize(
        address admin_,
        address haikuRouter_,
        address haikuSigner_
    ) external initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(VAULT_MANAGER_ROLE, admin_);

        haikuRouter = haikuRouter_;
        haikuSigner = haikuSigner_;
        maxSlippage = 300; // 3% default
        maxCalldataAge = 300; // 5 minutes default
    }

    /*//////////////////////////////////////////////////////////////
                            CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Execute Haiku calldata for auto-compounding
     * @param payload Signed calldata payload from Haiku API
     * @param minAmountOut Minimum expected output amount for slippage protection
     * @return amountOut Actual amount received from the operation
     */
    function executeHaikuCalldata(
        bytes calldata payload,
        uint256 minAmountOut
    ) external override nonReentrant whenNotPaused returns (uint256 amountOut) {
        // Only authorized vaults can execute calldata
        if (!authorizedVaults[msg.sender]) {
            revert UnauthorizedRouter();
        }

        HaikuPayload memory decodedPayload = _decodePayload(payload);
        
        // Validate the payload
        _validatePayload(decodedPayload, minAmountOut);
        
        // Mark calldata as used to prevent replay
        bytes32 calldataHash = keccak256(payload);
        usedCalldataHashes[calldataHash] = true;
        
        // Execute the router call
        uint256 balanceBefore = IERC20(decodedPayload.tokenOut).balanceOf(decodedPayload.recipient);
        
        (bool success, bytes memory result) = haikuRouter.call(decodedPayload.routerCalldata);
        if (!success) {
            revert InvalidCalldata();
        }
        
        uint256 balanceAfter = IERC20(decodedPayload.tokenOut).balanceOf(decodedPayload.recipient);
        amountOut = balanceAfter - balanceBefore;
        
        // Check minimum output
        if (amountOut < minAmountOut) {
            revert InsufficientOutput();
        }
        
        emit HaikuCallExecuted(
            msg.sender,
            address(0), // strategy address could be passed as parameter
            decodedPayload.amountIn,
            amountOut,
            calldataHash
        );
        
        return amountOut;
    }

    /**
     * @notice Validate Haiku calldata without executing
     * @param payload Signed calldata payload to validate
     * @return isValid Whether the calldata is valid
     * @return expectedOutput Expected output amount
     */
    function validateHaikuCalldata(
        bytes calldata payload
    ) external view override returns (bool isValid, uint256 expectedOutput) {
        try this._validatePayloadView(payload) returns (uint256 expected) {
            return (true, expected);
        } catch {
            return (false, 0);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Authorize a vault to use this adapter
     * @param vault Address of the vault to authorize
     */
    function authorizeVault(address vault) external onlyRole(VAULT_MANAGER_ROLE) {
        authorizedVaults[vault] = true;
    }

    /**
     * @notice Revoke vault authorization
     * @param vault Address of the vault to revoke
     */
    function revokeVault(address vault) external onlyRole(VAULT_MANAGER_ROLE) {
        authorizedVaults[vault] = false;
    }

    /**
     * @notice Update Haiku router address
     * @param newRouter New router address
     */
    function updateHaikuRouter(address newRouter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address oldRouter = haikuRouter;
        haikuRouter = newRouter;
        emit HaikuRouterUpdated(oldRouter, newRouter);
    }

    /**
     * @notice Update Haiku signer address
     * @param newSigner New signer address
     */
    function updateHaikuSigner(address newSigner) external onlyRole(DEFAULT_ADMIN_ROLE) {
        haikuSigner = newSigner;
    }

    /**
     * @notice Update maximum slippage
     * @param newMaxSlippage New maximum slippage in basis points
     */
    function updateMaxSlippage(uint256 newMaxSlippage) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newMaxSlippage <= 1000, "Slippage too high"); // Max 10%
        maxSlippage = newMaxSlippage;
    }

    /**
     * @notice Update maximum calldata age
     * @param newMaxAge New maximum age in seconds
     */
    function updateMaxCalldataAge(uint256 newMaxAge) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newMaxAge <= 3600, "Age too long"); // Max 1 hour
        maxCalldataAge = newMaxAge;
    }

    /**
     * @notice Pause the adapter
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the adapter
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Check if a vault is authorized to use this adapter
     * @param vault Address of the vault to check
     * @return authorized Whether the vault is authorized
     */
    function isAuthorizedVault(address vault) external view override returns (bool authorized) {
        return authorizedVaults[vault];
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Decode the payload bytes into HaikuPayload struct
     * @param payload Raw payload bytes
     * @return decoded HaikuPayload struct
     */
    function _decodePayload(bytes calldata payload) internal pure returns (HaikuPayload memory decoded) {
        // This is a simplified decoder - in practice, you'd implement based on Haiku's actual format
        (
            decoded.tokenIn,
            decoded.tokenOut,
            decoded.amountIn,
            decoded.amountOutMin,
            decoded.recipient,
            decoded.deadline,
            decoded.routerCalldata,
            decoded.signature
        ) = abi.decode(payload, (address, address, uint256, uint256, address, uint256, bytes, bytes));
    }

    /**
     * @notice Validate the decoded payload
     * @param decodedPayload The decoded payload to validate
     * @param minAmountOut Minimum expected output
     */
    function _validatePayload(
        HaikuPayload memory decodedPayload,
        uint256 minAmountOut
    ) internal view {
        // Check deadline
        if (block.timestamp > decodedPayload.deadline) {
            revert CalldataExpired();
        }
        
        // Check calldata age (deadline should be recent)
        if (decodedPayload.deadline > block.timestamp + maxCalldataAge) {
            revert CalldataExpired();
        }
        
        // Check minimum output against slippage
        uint256 maxSlippageAmount = (decodedPayload.amountIn * maxSlippage) / MAX_BPS;
        uint256 minExpected = decodedPayload.amountIn > maxSlippageAmount ? 
            decodedPayload.amountIn - maxSlippageAmount : 0;
        
        if (minAmountOut < minExpected) {
            revert SlippageTooHigh();
        }
        
        // Verify signature
        bytes32 messageHash = _getMessageHash(decodedPayload);
        bytes32 ethSignedMessageHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        
        address recoveredSigner = ethSignedMessageHash.recover(decodedPayload.signature);
        if (recoveredSigner != haikuSigner) {
            revert InvalidSignature();
        }
        
        // Check if calldata hash was already used
        bytes32 calldataHash = keccak256(abi.encode(decodedPayload));
        if (usedCalldataHashes[calldataHash]) {
            revert InvalidCalldata();
        }
    }

    /**
     * @notice External wrapper for validation (view function)
     * @param payload Raw payload to validate
     * @return expectedOutput Expected output amount
     */
    function _validatePayloadView(bytes calldata payload) external view returns (uint256 expectedOutput) {
        HaikuPayload memory decodedPayload = _decodePayload(payload);
        
        // Basic validation without state changes
        if (block.timestamp > decodedPayload.deadline) {
            revert CalldataExpired();
        }
        
        if (decodedPayload.deadline > block.timestamp + maxCalldataAge) {
            revert CalldataExpired();
        }
        
        // Verify signature
        bytes32 messageHash = _getMessageHash(decodedPayload);
        bytes32 ethSignedMessageHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        
        address recoveredSigner = ethSignedMessageHash.recover(decodedPayload.signature);
        if (recoveredSigner != haikuSigner) {
            revert InvalidSignature();
        }
        
        return decodedPayload.amountOutMin;
    }

    /**
     * @notice Generate message hash for signature verification
     * @param payload The payload to hash
     * @return messageHash The message hash
     */
    function _getMessageHash(HaikuPayload memory payload) internal pure returns (bytes32 messageHash) {
        return keccak256(abi.encodePacked(
            payload.tokenIn,
            payload.tokenOut,
            payload.amountIn,
            payload.amountOutMin,
            payload.recipient,
            payload.deadline,
            keccak256(payload.routerCalldata)
        ));
    }

    /**
     * @notice UUPS upgrade authorization
     */
    function _authorizeUpgrade(address newImplementation) 
        internal 
        override 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {}
}