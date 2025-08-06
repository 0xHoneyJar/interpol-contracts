// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "../../src/SFV1/interfaces/IStrategy.sol";

/**
 * @title MockStrategy
 * @notice Mock strategy for testing purposes
 */
contract MockStrategy is IStrategy {
    using SafeERC20 for IERC20;

    address public immutable asset;
    address public immutable vault;
    uint256 public currentDebt;
    uint256 public maxDebt;
    bool public isActive;
    uint256 public mockProfit;
    uint256 public mockLoss;
    uint256 private _totalAssets;

    constructor(address _asset, address _vault) {
        asset = _asset;
        vault = _vault;
        isActive = true;
        maxDebt = type(uint256).max;
    }

    // Mock functions for testing
    function setProfit(uint256 _profit) external {
        mockProfit = _profit;
        _totalAssets += _profit;
    }

    function setLoss(uint256 _loss) external {
        mockLoss = _loss;
        _totalAssets = _totalAssets > _loss ? _totalAssets - _loss : 0;
    }

    // IStrategy implementation
    function deployFunds(uint256 assets) external override {
        IERC20(asset).safeTransferFrom(vault, address(this), assets);
        currentDebt += assets;
        _totalAssets += assets;
    }

    function freeFunds(uint256 amount) external override returns (uint256 actualAmount) {
        actualAmount = amount > _totalAssets ? _totalAssets : amount;
        currentDebt = currentDebt > actualAmount ? currentDebt - actualAmount : 0;
        _totalAssets -= actualAmount;
        IERC20(asset).safeTransfer(vault, actualAmount);
        return actualAmount;
    }

    function report() external override returns (uint256 profit, uint256 loss) {
        profit = mockProfit;
        loss = mockLoss;
        mockProfit = 0;
        mockLoss = 0;
        return (profit, loss);
    }

    function tendTrigger() external view override returns (bool shouldTend, bytes memory data) {
        return (false, "");
    }

    function tend(uint256 totalIdle) external override {
        // Do nothing
    }

    function availableDepositLimit(address owner) external view override returns (uint256 limit) {
        return maxDebt > currentDebt ? maxDebt - currentDebt : 0;
    }

    function availableWithdrawLimit(address owner) external view override returns (uint256 limit) {
        return _totalAssets;
    }

    function emergencyWithdraw(uint256 amount) external override returns (uint256 actualAmount) {
        return this.freeFunds(amount);
    }

    // ERC4626 implementation (simplified)
    function totalAssets() external view override returns (uint256) {
        return _totalAssets;
    }

    function convertToShares(uint256 assets) external view override returns (uint256) {
        return assets;
    }

    function convertToAssets(uint256 shares) external view override returns (uint256) {
        return shares;
    }

    function maxDeposit(address) external view override returns (uint256) {
        return type(uint256).max;
    }

    function previewDeposit(uint256 assets) external view override returns (uint256) {
        return assets;
    }

    function deposit(uint256 assets, address receiver) external override returns (uint256) {
        return assets;
    }

    function maxMint(address) external view override returns (uint256) {
        return type(uint256).max;
    }

    function previewMint(uint256 shares) external view override returns (uint256) {
        return shares;
    }

    function mint(uint256 shares, address receiver) external override returns (uint256) {
        return shares;
    }

    function maxWithdraw(address owner) external view override returns (uint256) {
        return _totalAssets;
    }

    function previewWithdraw(uint256 assets) external view override returns (uint256) {
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) external override returns (uint256) {
        return assets;
    }

    function maxRedeem(address owner) external view override returns (uint256) {
        return _totalAssets;
    }

    function previewRedeem(uint256 shares) external view override returns (uint256) {
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) external override returns (uint256) {
        return shares;
    }

    // ERC20 implementation (minimal)
    function totalSupply() external view override returns (uint256) {
        return _totalAssets;
    }

    function balanceOf(address) external view override returns (uint256) {
        return 0;
    }

    function transfer(address, uint256) external override returns (bool) {
        return true;
    }

    function allowance(address, address) external view override returns (uint256) {
        return 0;
    }

    function approve(address, uint256) external override returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256) external override returns (bool) {
        return true;
    }

    // ERC20 metadata
    function name() external view override returns (string memory) {
        return "Mock Strategy";
    }

    function symbol() external view override returns (string memory) {
        return "MOCK";
    }

    function decimals() external view override returns (uint8) {
        return 18;
    }
}