// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib as STL} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib as FPML} from "solady/utils/FixedPointMathLib.sol";

import {HoneyLocker} from "./HoneyLocker.sol";

// prettier-ignore
contract Beekeeper is Ownable {
    /*###############################################################
                            ERRORS
    ###############################################################*/
    error Beekeeper__NotAReferrer();
    error Beekeeper__NoCodeForToken();
    /*###############################################################
                            EVENTS
    ###############################################################*/
    event Beekeeper__FeesDistributed(address indexed recipient, address indexed token, uint256 amount);
    /*###############################################################
                            STORAGE
    ###############################################################*/
    address public treasury;
    uint256 public standardReferrerFeeShare = 2500; // BPS
    
    mapping(address referrer => bool authorized)            public      isReferrer;
    mapping(address referrer => address overridingReferrer) public      referrerOverrides;
    mapping(address referrer => uint256 shareOfFeeInBps)    public      _referrerFeeShare;
    /*###############################################################
                            CONSTRUCTOR
    ###############################################################*/
    constructor(address _owner, address _treasury) {
        _initializeOwner(_owner);
        treasury = _treasury;
    }
    /*###############################################################
                            OWNER ONLY
    ###############################################################*/
    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }
    function setStandardReferrerFeeShare(uint256 _standardReferrerFeeShare) external onlyOwner {
        standardReferrerFeeShare = _standardReferrerFeeShare;
    }
    function setReferrer(address _referrer, bool _isReferrer) external onlyOwner {
        isReferrer[_referrer] = _isReferrer;
    }
    /*
        The referrer override is to be used if the original referrer address private key is compromised.
        The overriding referrer will receive the fees instead of the original referrer.
        The original referrer HAS to be maintained as a valid referrer.
    */
    function setReferrerOverride(address _referrer, address _overridingReferrer) external onlyOwner {
        if (!isReferrer[_referrer]) revert Beekeeper__NotAReferrer();
        referrerOverrides[_referrer] = _overridingReferrer;
        _referrerFeeShare[_overridingReferrer] = _referrerFeeShare[_referrer];
    }
    function setReferrerFeeShare(address _referrer, uint256 _shareOfFeeInBps) external onlyOwner {
        if (!isReferrer[_referrer]) revert Beekeeper__NotAReferrer();
        _referrerFeeShare[_referrer] = _shareOfFeeInBps;
        // also update the overriding referrer fee share if it exists
        if (referrerOverrides[_referrer] != address(0)) {
            _referrerFeeShare[referrerOverrides[_referrer]] = _shareOfFeeInBps;
        }
    }
    /*###############################################################
                            VIEW ONLY
    ###############################################################*/
    /// @notice                 Returns the fee share for a given referrer
    /// @dev                    If a custom fee share is set for the referrer, it returns that value.
    ///                         Otherwise, it returns the standard referrer fee share.
    ///
    /// @param _referrer        The address of the referrer
    /// @return _               The fee share for the referrer in basis points (bps)
    function referrerFeeShare(address _referrer) public view returns (uint256) {
        return _referrerFeeShare[_referrer] != 0 ? _referrerFeeShare[_referrer] : standardReferrerFeeShare;
    }
    /*###############################################################
                            INTERNAL
    ###############################################################*/
    /*###############################################################
                            EXTERNAL
    ###############################################################*/

    /// @notice             Distributes fees between the referrer and the treasury
    /// @dev                If the referrer is not authorized, all fees go to the treasury
    /// @param _referrer    The address of the referrer
    /// @param _token       The address of the token being distributed (address(0) for native token)
    /// @param _amount      The total amount of fees to be distributed
    /// @custom:emits       FeesDistributed emitted for each recipient (referrer and treasury) with their respective amounts
    function distributeFees(address _referrer, address _token, uint256 _amount) external payable {
        bool isBera = _token == address(0);
        if (!isBera && _token.code.length == 0) revert Beekeeper__NoCodeForToken();
        // if not an authorized referrer, send everything to treasury
        if (!isReferrer[_referrer]) {
            isBera ? STL.safeTransferETH(treasury, _amount) : STL.safeTransfer(_token, treasury, _amount);
            emit Beekeeper__FeesDistributed(treasury, _token, _amount);
            return;
        }
        // use the referrer fee override if it exists, otherwise use the original referrer
        address referrer = referrerOverrides[_referrer] != address(0) ? referrerOverrides[_referrer] : _referrer;
        uint256 referrerFeeShareInBps = referrerFeeShare(referrer);
        uint256 referrerFee = FPML.mulDivUp(_amount, referrerFeeShareInBps, 10000);

        if (isBera) {
            STL.safeTransferETH(referrer, referrerFee);
            STL.safeTransferETH(treasury, _amount - referrerFee);
        } else {
            STL.safeTransfer(_token, referrer, referrerFee);
            STL.safeTransfer(_token, treasury, _amount - referrerFee);
        }

        emit Beekeeper__FeesDistributed(referrer, _token, referrerFee);
        emit Beekeeper__FeesDistributed(treasury, _token, _amount - referrerFee);
    }
}