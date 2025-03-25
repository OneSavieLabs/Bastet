// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.19;

// interfaces
import {IWETH9} from "@napier/v1-tranche/interfaces/IWETH9.sol";
import {ILRTOracle} from "./interfaces/ILRTOracle.sol";
import {ILRTDepositPool} from "./interfaces/ILRTDepositPool.sol";

// libs
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable@4.9.3/token/ERC20/IERC20Upgradeable.sol";
import {LSTAdapterStorage} from "../../Structs.sol";
import "../../Constants.sol" as Constants;

import {BaseLSTAdapterUpgradeable} from "../BaseLSTAdapterUpgradeable.sol";

/// @notice RsETHAdapter - eRsETH (Napier rsETH Adapter)
/// @notice rsETH is a Liquid Restaked Token (LRT) issued by Kelp DAO designed
/// to offer liquidity to illiquid assets deposited into restaking platforms,
///  such as EigenLayer. It aims to address the risks and challenges posed by the current offering of restaking
contract RsETHAdapter is BaseLSTAdapterUpgradeable {
    /// @notice LRTDepositPool
    ILRTDepositPool constant RSETH_DEPOSIT_POOL = ILRTDepositPool(Constants.RSETH_DEPOSIT_POOL);

    /// @notice LRTOracle
    ILRTOracle constant RSETH_ORACLE = ILRTOracle(Constants.RSETH_ORACLE);

    /// @notice rsETH
    IERC20Upgradeable constant RSETH = IERC20Upgradeable(Constants.RSETH);

    /// @notice RSETH referral id
    string constant REFERRAL_ID = "Napier-RsETHAdapter";

    error OnlyWETHOrRETH();
    error InvariantViolation();
    error MinAmountToDepositError();
    error ProtocolPaused();

    receive() external payable {}

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _owner,
        address _rebalancer,
        uint256 _maxStakeLimit,
        uint256 _stakeLimitIncreasePerBlock
    ) public initializer {
        __BaseLSTAdapter_init(_owner, _rebalancer, _maxStakeLimit, _stakeLimitIncreasePerBlock);
        __ERC20_init("Napier rsETH Adapter", "eRsETH");
    }

    /// @notice Claim withdrawal from Kelp
    /// @dev Kelp doesn't have claim functionality yet.
    function claimWithdrawal(uint256) external pure override {
        revert NotImplemented();
    }

    ///////////////////////////////////////////////////////////////////////////
    // Rebalancer functions
    ///////////////////////////////////////////////////////////////////////////

    /// @notice Kelp allows ETH, ETHx, stETH or sfrxETH via LRTDepositPool.
    /// @dev Kelp has a limit on the amount of ETH that can be staked.
    /// @dev Need to check the current staking limit before staking to prevent DoS.
    function _stake(uint256 stakeAmount) internal override returns (uint256) {
        if (stakeAmount == 0) return 0;

        // Check LRTDepositPool stake limit
        uint256 stakeLimit = RSETH_DEPOSIT_POOL.getAssetCurrentLimit(Constants.ETH);
        if (stakeAmount > stakeLimit) {
            // Cap stake amount
            stakeAmount = stakeLimit;
        }
        // Check LRTDepositPool minAmountToDeposit
        if (stakeAmount <= RSETH_DEPOSIT_POOL.minAmountToDeposit()) revert MinAmountToDepositError();
        // Check paused of LRTDepositPool
        if (RSETH_DEPOSIT_POOL.paused()) revert ProtocolPaused();

        // Interact
        IWETH9(Constants.WETH).withdraw(stakeAmount);
        uint256 _rsETHAmt = RSETH.balanceOf(address(this));
        RSETH_DEPOSIT_POOL.depositETH{value: stakeAmount}(0, REFERRAL_ID);
        _rsETHAmt = RSETH.balanceOf(address(this)) - _rsETHAmt;

        if (_rsETHAmt == 0) revert InvariantViolation();

        return stakeAmount;
    }

    /// @dev Puffer doesn't have withdraw function yet.
    function requestWithdrawal() external pure override {
        revert NotImplemented();
    }

    /// @dev Puffer doesn't have withdraw function yet.
    function requestWithdrawalAll() external pure override {
        revert NotImplemented();
    }

    /// @dev Puffer doesn't have withdraw function yet.
    function _requestWithdrawal(uint256) internal pure override returns (uint256, uint256) {
        revert NotImplemented();
    }

    function totalAssets() public view override returns (uint256) {
        LSTAdapterStorage storage $ = _getStorage();
        return $.totalQueueEth + $.bufferEth + (RSETH.balanceOf(address(this)) * RSETH_ORACLE.rsETHPrice()) / 1e18;
    }
}