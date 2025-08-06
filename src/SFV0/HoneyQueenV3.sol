// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {FixedPointMathLib as FPML} from "solady/utils/FixedPointMathLib.sol";

import {ICUB} from "./utils/ICUB.sol";

contract HoneyQueenV3 is UUPSUpgradeable, OwnableUpgradeable {
    /*###############################################################
                            ERRORS
    ###############################################################*/
    error HoneyQueen__AdapterNotApproved();
    error HoneyQueen__VaultNotApproved();
    error HoneyQueen__InvalidProtocol();
    error HoneyQueen__AdapterNotSet();
    /*###############################################################
                            EVENTS
    ###############################################################*/
    /*###############################################################
                            STRUCTS
    ###############################################################*/
    /*###############################################################
                            STORAGE
    ###############################################################*/
    address                                             public      BGT;

    mapping(string protocol => address adapterBeacon)   public      adapterBeaconOfProtocol;
    // have to build a reverse mapping to allow lockers to query
    mapping(address adapterBeacon => string protocol)   public      protocolOfAdapterBeacon;
    mapping(address vault => string protocol)           public      protocolOfVault;
    mapping(address vault => address token)             public      tokenOfVault;
    
    // this is for cases where gauges give you a NFT to represent your staking position
    mapping(address token => bool blocked)              public      isTokenBlocked;
    mapping(address token => bool isRewardToken)        public      isRewardToken;
    address                                             public      beekeeper;
    uint256                                             public      protocolFees;
    ICUB                                                public      badges;

    address                                             public      BGM;

    uint256[39] __gap;
    /*###############################################################
                            CONSTRUCTOR
    ###############################################################*/
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    /*###############################################################
                            INITIALIZER
    ###############################################################*/
    function initialize(address _owner, address _BGT) external initializer {
        BGT = _BGT;
        __Ownable_init(_owner);
    }
    /*###############################################################
                            PROXY MANAGEMENT
    ###############################################################*/
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    /*###############################################################
                            ADAPTERS MANAGEMENT
    ###############################################################*/
    /**
     * @notice          Adds a new adapter beacon for a protocol
     * @param protocol  The protocol name
     * @param adapterBeacon   The adapter beacon address
     */
    function setAdapterBeaconForProtocol(string calldata protocol, address adapterBeacon) external onlyOwner {
        adapterBeaconOfProtocol[protocol] = adapterBeacon;
        protocolOfAdapterBeacon[adapterBeacon] = protocol;
    }
    /**
     * @notice          Approves or revokes a vault for a protocol
     * @param protocol  The protocol name
     * @param vault     The vault address
     * @param approved  Whether the vault should be approved
     */
    function setVaultForProtocol(
        string calldata protocol,
        address vault,
        address token,
        bool approved
    ) external onlyOwner {
        if (approved) {
            protocolOfVault[vault] = protocol;
            tokenOfVault[vault] = token;
        } else {
            delete protocolOfVault[vault];
            delete tokenOfVault[vault];
        }
    }
    /*###############################################################
                            LOCKERS MANAGEMENT
    ###############################################################*/
    /*###############################################################
                            OWNER MANAGEMENT
    ###############################################################*/
    function setTokenBlocked(address token, bool blocked) external onlyOwner {
        isTokenBlocked[token] = blocked;
    }

    function setIsRewardToken(address token, bool _isRewardToken) external onlyOwner {
        isRewardToken[token] = _isRewardToken;
    }

    function setBeekeeper(address _beekeeper) external onlyOwner {
        beekeeper = _beekeeper;
    }

    function setProtocolFees(uint256 _protocolFees) external onlyOwner {
        protocolFees = _protocolFees;
    }

    function setBadges(address _badges) external onlyOwner {
        badges = ICUB(_badges);
    }

    function setBGM(address _BGM) external onlyOwner {
        BGM = _BGM;
    }
    /*###############################################################
                            EXTERNAL FUNCTIONS
    ###############################################################*/
    /*###############################################################
                            READ FUNCTIONS
    ###############################################################*/
    function computeFees(address user, bool applyDiscount, uint256 amount) public view returns (uint256) {
        uint256 fees = FPML.mulDivUp(amount, protocolFees, 10000);
        if (!applyDiscount) return fees;
        
        uint256 badgesPercentageOfUser = badges.badgesPercentageOfUser(user);
        if (badgesPercentageOfUser == 0) return fees;
        
        // Calculate a linear discount on the fees based on the user's badge holding.
        // The discount fraction is the proportion of badges owned (in bps) scaled to a maximum discount of 69%.
        // That is, discount = (badgesPercentageOfUser / 10000) * 6900 (in basis points)
        uint256 maxDiscount = 6900;
        uint256 discount = FPML.mulDivUp(badgesPercentageOfUser, maxDiscount, 10000);
        if (discount > maxDiscount) {
            discount = maxDiscount;
        }
        return FPML.mulDivUp(fees, 10000 - discount, 10000);
    }

    function isVaultValidForAdapterBeacon(address adapterBeacon, address vault) public view returns (bool) {
        return adapterBeaconOfProtocol[protocolOfVault[vault]] == adapterBeacon;
    }

    function version() external pure returns (string memory) {
        return "3.0";
    }

    function getImplementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }
}
