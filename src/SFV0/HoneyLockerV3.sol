// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20} from "solady/tokens/ERC20.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {ERC1155} from "solady/tokens/ERC1155.sol";
import {SafeTransferLib as STL} from "solady/utils/SafeTransferLib.sol";

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import {BaseVaultAdapter as BVA} from "./adapters/BaseVaultAdapter.sol";
import {IBGTStationGauge} from "./adapters/BGTStationAdapter.sol";
import {IBGT} from "./utils/IBGT.sol";
import {IBGTStaker} from "./utils/IBGTStaker.sol";
import {HoneyQueenV3} from "./HoneyQueenV3.sol";
import {Beekeeper} from "./Beekeeper.sol";
import {TokenReceiver} from "./utils/TokenReceiver.sol";
import {IUniswapV3} from "./utils/IUniswapV3.sol";
import {IBGM} from "./utils/IBGM.sol";

contract HoneyLockerV3 is OwnableUpgradeable, TokenReceiver {
    /*###############################################################
                            ERRORS
    ###############################################################*/
    error HoneyLocker__AdapterAlreadyRegistered();
    error HoneyLocker__AdapterNotFound();

    error HoneyLocker__NotAuthorized();
    error HoneyLocker__ExpirationNotMatching();
    error HoneyLocker__HasToBeLPToken();
    error HoneyLocker__NotExpiredYet();
    error HoneyLocker__WithdrawalFailed();
    error HoneyLocker__CannotBeLPToken();
    error HoneyLocker__TokenBlocked();
    error HoneyLocker__NotAuthorizedUpgrade();
    error HoneyLocker__ExpirationMustBeGreaterThanZero();
    /*###############################################################
                            EVENTS
    ###############################################################*/
    event HoneyLocker__Deposited(address indexed LPToken, uint256 amountOrId);
    event HoneyLocker__LockedUntil(address indexed LPToken, uint256 expiration);
    event HoneyLocker__Withdrawn(address indexed LPToken, uint256 amountOrId);

    event HoneyLocker__Staked(address indexed vault, address indexed LPToken, uint256 amountOrId);
    event HoneyLocker__Unstaked(address indexed vault, address indexed LPToken, uint256 amountOrId);
    event HoneyLocker__Claimed(address indexed vault, address indexed rewardToken, uint256 amount);
    event HoneyLocker__Wildcard(address indexed vault, uint8 indexed func, bytes args);
    event HoneyLocker__ClaimedFeesOfLP(address indexed LPToken, uint256 amount0, uint256 amount1);

    event HoneyLocker__OperatorSet(address indexed operator);
    event HoneyLocker__TreasurySet(address indexed treasury);

    event HoneyLocker__AdapterRegistered(string indexed protocol, address adapter);
    /*###############################################################
                            STORAGE
    ###############################################################*/
    HoneyQueenV3                                    public  honeyQueen;
    mapping(string protocol => BVA adapter)         public  adapterOfProtocol;

    mapping(address LPToken => uint256 staked)      public  totalLPStaked;
    mapping(address vault   => uint256 staked)      public  vaultLPStaked;

    mapping(address LPToken => uint256 expiration)  public  expirations;
    bool                                            public  unlocked;
    address                                         public  referrer;
    address                                         public  treasury;            
    address                                         public  operator;

    uint256[41] __gap;
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
    function initialize(address _honeyQueen, address _owner, address _referrer, bool _unlocked)
    external
    initializer 
    {
        __Ownable_init(_owner);
        honeyQueen = HoneyQueenV3(_honeyQueen);
        unlocked = _unlocked;
        referrer = _referrer;
    }
    /*###############################################################
                            MODIFIERS
    ###############################################################*/
    modifier onlyValidAdapter(address vault) {
        if (address(_getAdapter(vault)) == address(0)) revert HoneyLocker__AdapterNotFound();
        _;
    }
    modifier onlyOwnerOrOperator() {
        if (msg.sender != owner() && msg.sender != operator) revert HoneyLocker__NotAuthorized();
        _;
    }
    modifier onlyUnblockedTokens(address _token) {
        if (!unlocked && honeyQueen.isTokenBlocked(_token)) revert HoneyLocker__TokenBlocked();
        _;
    }
    /*###############################################################
                            ADAPTERS MANAGEMENT
    ###############################################################*/
    function registerAdapter(string calldata protocol) external onlyOwner {
        BVA adapter = adapterOfProtocol[protocol];
        if (address(adapter) != address(0)) revert HoneyLocker__AdapterAlreadyRegistered();

        address adapterBeacon = honeyQueen.adapterBeaconOfProtocol(protocol);
        bytes memory data = abi.encodeWithSelector(BVA.initialize.selector, address(this), address(honeyQueen), adapterBeacon);
        address newAdapter = address(new BeaconProxy(adapterBeacon, data));

        adapterOfProtocol[protocol] = BVA(newAdapter);

        emit HoneyLocker__AdapterRegistered(protocol, newAdapter);
    }
    /*###############################################################
                            OWNER
    ###############################################################*/
    function setOperator(address _operator) external onlyOwner {
        operator = _operator;
        emit HoneyLocker__OperatorSet(_operator);
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
        emit HoneyLocker__TreasurySet(_treasury);
    }
    /*###############################################################
                            INTERNAL
    ###############################################################*/
    function _getAdapter(address vault) internal view returns (BVA adapter) {
        return adapterOfProtocol[honeyQueen.protocolOfVault(vault)];
    }
    /*###############################################################
                            VAULT MANAGEMENT
    ###############################################################*/
    function stake(address vault, uint256 amount) external onlyValidAdapter(vault) onlyOwnerOrOperator {
        BVA adapter = _getAdapter(vault);
        address token = adapter.stakingToken(vault);

        STL.safeApprove(token, address(adapter), amount);
        uint256 staked = adapter.stake(vault, amount);

        totalLPStaked[token] += staked;
        vaultLPStaked[vault] += staked;

        emit HoneyLocker__Staked(vault, token, staked);
    }

    function unstake(address vault, uint256 amount) external onlyValidAdapter(vault) onlyOwnerOrOperator {
        BVA adapter = _getAdapter(vault);
        address token = adapter.stakingToken(vault);

        uint256 unstaked = adapter.unstake(vault, amount);

        totalLPStaked[token] -= unstaked;
        vaultLPStaked[vault] -= unstaked;

        emit HoneyLocker__Unstaked(vault, token, unstaked);
    }

    function claim(address vault) external onlyValidAdapter(vault) onlyOwnerOrOperator returns (address[] memory, uint256[] memory) {
        BVA adapter = _getAdapter(vault);
        (address[] memory rewardTokens, uint256[] memory earned) = adapter.claim(vault);
        for (uint256 i; i < rewardTokens.length; i++) {
            emit HoneyLocker__Claimed(vault, rewardTokens[i], earned[i]);
        }
        return (rewardTokens, earned);
    }
    
    function wildcard(address vault, uint8 func, bytes calldata args) external onlyValidAdapter(vault) onlyOwnerOrOperator {
        BVA adapter = _getAdapter(vault);
        adapter.wildcard(vault, func, args);
        emit HoneyLocker__Wildcard(vault, func, args);
    }
    /*###############################################################
                            BGT MANAGEMENT
    ###############################################################*/
    function claimBGTRewards() external onlyOwnerOrOperator {
        IBGTStaker staker = IBGTStaker(IBGT(honeyQueen.BGT()).staker());
        uint256 rewards = staker.earned(address(this));
        staker.getReward();
        emit HoneyLocker__Claimed(address(staker), staker.rewardToken(), rewards);
    }

    function burnBGTForBERA(uint256 _amount) external onlyOwnerOrOperator {
        IBGT(honeyQueen.BGT()).redeem(address(this), _amount);
        withdrawBERA(_amount);
    }

    function queueBoost(uint128 amount, bytes calldata validator) external onlyOwnerOrOperator {
        IBGT(honeyQueen.BGT()).queueBoost(validator, amount);
    }

    function activateBoost(bytes calldata validator) external onlyOwnerOrOperator {
        require(IBGT(honeyQueen.BGT()).activateBoost(address(this), validator));
    }

    function cancelQueuedBoost(uint128 amount, bytes calldata validator) external onlyOwnerOrOperator {
        IBGT(honeyQueen.BGT()).cancelBoost(validator, amount);
    }

    function queueDropBoost(uint128 amount, bytes calldata validator) external onlyOwnerOrOperator {
        IBGT(honeyQueen.BGT()).queueDropBoost(validator, amount);
    }

    function cancelDropBoost(uint128 amount, bytes calldata validator) external onlyOwnerOrOperator {
        IBGT(honeyQueen.BGT()).cancelDropBoost(validator, amount);
    }

    function dropBoost(uint128 amount, bytes calldata validator) external onlyOwnerOrOperator {
        require(IBGT(honeyQueen.BGT()).dropBoost(address(this), validator));
    }

    function delegate(address delegatee) external onlyOwnerOrOperator {
        IBGT(honeyQueen.BGT()).delegate(delegatee);
    }
    /*###############################################################
                            BGM MANAGEMENT
    ###############################################################*/
    function contributeBGM(uint256 _amount) external onlyOwnerOrOperator {
        IBGM(honeyQueen.BGM()).contribute(_amount);
    }

    function burnBGMForBERA(uint256 _amount) external onlyOwnerOrOperator {
        IBGM(honeyQueen.BGM()).redeem(_amount);
        withdrawBERA(_amount);
    }

    function queueBoostBGM(uint128 amount, bytes calldata validator) external onlyOwnerOrOperator {
        IBGM(honeyQueen.BGM()).delegate(validator, amount);
    }

    function cancelQueuedBoostBGM(uint128 amount, bytes calldata validator) external onlyOwnerOrOperator {
        IBGM(honeyQueen.BGM()).cancel(validator, amount);
    }

    function queueDropBoostBGM(uint128 amount, bytes calldata validator) external onlyOwnerOrOperator {
        IBGM(honeyQueen.BGM()).unbondQueue(validator, amount);
    }

    function cancelDropBoostBGM(uint128 amount, bytes calldata validator) external onlyOwnerOrOperator {
        IBGM(honeyQueen.BGM()).cancelUnbond(validator, amount);
    }

    function dropBoostBGM(uint128 amount, bytes calldata validator) external onlyOwnerOrOperator {
        IBGM(honeyQueen.BGM()).unbond(validator);
    }
    /*###############################################################
                            LP MANAGEMENT
    ###############################################################*/
    /// @notice             Deposits and locks LP tokens in the HoneyLocker
    /// @dev                Only the owner or migrating vault can call this function
    /// @param _LPToken     The address of the LP token to deposit and lock
    /// @param _amountOrId  The amount or ID of the LP token to deposit
    /// @param _expiration  The expiration timestamp for the lock
    /// @custom:throws      ExpirationNotMatching if the new expiration is less than the existing one for non-unlocked tokens
    /// @custom:emits       Deposited event with the LP token address and amount or ID deposited
    /// @custom:emits       LockedUntil event with the LP token address and expiration timestamp
    function depositAndLock(address _LPToken, uint256 _amountOrId, uint256 _expiration)
    external
    onlyOwnerOrOperator
    onlyUnblockedTokens(_LPToken) 
    {
        if (_expiration == 0) revert HoneyLocker__ExpirationMustBeGreaterThanZero();
        if (!unlocked && expirations[_LPToken] != 0 && _expiration < expirations[_LPToken]) {
            revert HoneyLocker__ExpirationNotMatching();
        }

        expirations[_LPToken] = unlocked ? 1 : _expiration;

        // using transferFrom from ERC721 because same signature for ERC20
        // with the difference that ERC721 doesn't expect a return value
        ERC721(_LPToken).transferFrom(msg.sender, address(this), _amountOrId);

        emit HoneyLocker__Deposited(_LPToken, _amountOrId);
        emit HoneyLocker__LockedUntil(_LPToken, _expiration);
    }

    function withdrawLPToken(address _LPToken, uint256 _amountOrId)
    external
    onlyUnblockedTokens(_LPToken)
    onlyOwnerOrOperator 
    {
        if (honeyQueen.isRewardToken(_LPToken)) revert HoneyLocker__HasToBeLPToken();
        if (expirations[_LPToken] == 0) revert HoneyLocker__HasToBeLPToken();
        if (block.timestamp < expirations[_LPToken]) revert HoneyLocker__NotExpiredYet();

        // self approval only needed for ERC20, try/catch in case it's an ERC721
        try ERC721(_LPToken).approve(address(this), _amountOrId) {} catch {}
        ERC721(_LPToken).transferFrom(address(this), recipient(), _amountOrId);
        emit HoneyLocker__Withdrawn(_LPToken, _amountOrId);
    }

    /*
        Claim accumulated fees of NFT LP tokens on Uniswap V3 contracts.
    */
    function claimFeesOfLP(address _LPToken, uint256 _tokenId) external onlyOwnerOrOperator {
        IUniswapV3.CollectParams memory params =
            IUniswapV3.CollectParams({
                tokenId: _tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });

        (uint256 amount0, uint256 amount1) = IUniswapV3(_LPToken).collect(params);
        emit HoneyLocker__ClaimedFeesOfLP(_LPToken, amount0, amount1);
    }

    /*###############################################################
                            TOKENS WITHDRAWALS
    ###############################################################*/
    function withdrawBERA(uint256 _amount) public onlyOwnerOrOperator {
        uint256 fees = honeyQueen.computeFees(owner(), unlocked, _amount);
        STL.safeTransferETH(recipient(), _amount - fees);
        Beekeeper(honeyQueen.beekeeper()).distributeFees{value: fees}(referrer, address(0), fees);
        emit HoneyLocker__Withdrawn(address(0), _amount - fees);
    }

    function withdrawERC20(address _token, uint256 _amount) external onlyUnblockedTokens(_token) onlyOwnerOrOperator {
        // cannot withdraw any lp token that has an expiration
        if (expirations[_token] != 0) revert HoneyLocker__CannotBeLPToken();
        Beekeeper beekeeper = Beekeeper(honeyQueen.beekeeper());
        uint256 fees = honeyQueen.computeFees(owner(), unlocked, _amount);
        SafeERC20.safeTransfer(IERC20(_token), recipient(), _amount - fees);
        SafeERC20.safeTransfer(IERC20(_token), address(beekeeper), fees);
        beekeeper.distributeFees(referrer, _token, fees);
        emit HoneyLocker__Withdrawn(_token, _amount - fees);
    }

    function withdrawERC721(address _token, uint256 _id) external onlyUnblockedTokens(_token) onlyOwnerOrOperator {
        if (expirations[_token] != 0) revert HoneyLocker__CannotBeLPToken();
        ERC721(_token).safeTransferFrom(address(this), recipient(), _id);
        emit HoneyLocker__Withdrawn(_token, _id);
    }

    function withdrawERC1155(address _token, uint256 _id, uint256 _amount, bytes calldata _data)
        external
        onlyUnblockedTokens(_token)
        onlyOwnerOrOperator
    {
        ERC1155(_token).safeTransferFrom(address(this), recipient(), _id, _amount, _data);
        emit HoneyLocker__Withdrawn(_token, _id);
    }
    /*###############################################################
                            VIEW LOGIC
    ###############################################################*/
    /// @notice         Returns the recipient address for rewards and LP tokens withdrawals
    /// @dev            If treasury is set, returns treasury address. Otherwise, returns owner address.
    /// @return address The address of the recipient (either treasury or owner)
    function recipient() public view returns (address) {
        return treasury == address(0) ? owner() : treasury;
    }
    function version() external pure returns (string memory) {
        return "3.0";
    }
    /*###############################################################
                            PUBLIC LOGIC
    ###############################################################*/
    receive() external payable {}
}
