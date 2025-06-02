// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity 0.8.26;

import {BaseMigrator, IV3NonfungiblePositionManager} from ""../base/BaseMigrator.sol"";
import {IBinMigrator, PoolKey} from ""./interfaces/IBinMigrator.sol"";
import {IBinPositionManager} from ""./interfaces/IBinPositionManager.sol"";
import {IAllowanceTransfer} from ""permit2/src/interfaces/IAllowanceTransfer.sol"";
import {Currency, CurrencyLibrary} from ""infinity-core/src/types/Currency.sol"";
import {SafeCast} from ""@openzeppelin/contracts/utils/math/SafeCast.sol"";
import {Plan, Planner} from ""../libraries/Planner.sol"";
import {Actions} from ""../libraries/Actions.sol"";
import {ActionConstants} from ""../libraries/ActionConstants.sol"";
import {ReentrancyLock} from ""../base/ReentrancyLock.sol"";

contract BinMigrator is IBinMigrator, BaseMigrator, ReentrancyLock {
    using SafeCast for uint256;

    IBinPositionManager public immutable binPositionManager;

    constructor(address _WETH9, address _binPositionManager, IAllowanceTransfer _permit2)
        BaseMigrator(_WETH9, _binPositionManager, _permit2)
    {
        binPositionManager = IBinPositionManager(_binPositionManager);
    }

    /// @inheritdoc IBinMigrator
    function migrateFromV2(
        V2PoolParams calldata v2PoolParams,
        InfiBinPoolParams calldata infiPoolParams,
        uint256 extraAmount0,
        uint256 extraAmount1
    ) external payable override isNotLocked whenNotPaused {
        bool shouldReversePair = checkTokensOrderAndMatchFromV2(
            v2PoolParams.pair, infiPoolParams.poolKey.currency0, infiPoolParams.poolKey.currency1
        );
        (uint256 amount0Received, uint256 amount1Received) = withdrawLiquidityFromV2(v2PoolParams, shouldReversePair);

        /// @notice if user manually specify the price range, they might need to send extra token
        batchAndNormalizeTokens(
            infiPoolParams.poolKey.currency0, infiPoolParams.poolKey.currency1, extraAmount0, extraAmount1
        );

        uint256 amount0Input = amount0Received + extraAmount0;
        uint256 amount1Input = amount1Received + extraAmount1;
        IBinPositionManager.BinAddLiquidityParams memory addLiquidityParams = IBinPositionManager.BinAddLiquidityParams({
            poolKey: infiPoolParams.poolKey,
            amount0: amount0Input.toUint128(),
            amount1: amount1Input.toUint128(),
            amount0Max: infiPoolParams.amount0Max,
            amount1Max: infiPoolParams.amount1Max,
            activeIdDesired: infiPoolParams.activeIdDesired,
            idSlippage: infiPoolParams.idSlippage,
            deltaIds: infiPoolParams.deltaIds,
            distributionX: infiPoolParams.distributionX,
            distributionY: infiPoolParams.distributionY,
            to: infiPoolParams.to,
            hookData: infiPoolParams.hookData
        });

        (uint256 amount0Consumed, uint256 amount1Consumed) =
            _addLiquidityToTargetPool(addLiquidityParams, infiPoolParams.deadline);

        // refund if necessary, ETH is supported by CurrencyLib
        unchecked {
            if (amount0Input > amount0Consumed) {
                infiPoolParams.poolKey.currency0.transfer(infiPoolParams.to, amount0Input - amount0Consumed);
            }
            if (amount1Input > amount1Consumed) {
                infiPoolParams.poolKey.currency1.transfer(infiPoolParams.to, amount1Input - amount1Consumed);
            }
        }
    }

    /// @inheritdoc IBinMigrator
    function migrateFromV3(
        V3PoolParams calldata v3PoolParams,
        InfiBinPoolParams calldata infiPoolParams,
        uint256 extraAmount0,
        uint256 extraAmount1
    ) external payable override isNotLocked whenNotPaused {
        bool shouldReversePair = checkTokensOrderAndMatchFromV3(
            v3PoolParams.nfp, v3PoolParams.tokenId, infiPoolParams.poolKey.currency0, infiPoolParams.poolKey.currency1
        );
        (uint256 amount0Received, uint256 amount1Received) = withdrawLiquidityFromV3(v3PoolParams, shouldReversePair);

        /// @notice if user manually specify the price range, they need to send extra token
        batchAndNormalizeTokens(
            infiPoolParams.poolKey.currency0, infiPoolParams.poolKey.currency1, extraAmount0, extraAmount1
        );

        uint256 amount0Input = amount0Received + extraAmount0;
        uint256 amount1Input = amount1Received + extraAmount1;
        IBinPositionManager.BinAddLiquidityParams memory addLiquidityParams = IBinPositionManager.BinAddLiquidityParams({
            poolKey: infiPoolParams.poolKey,
            amount0: amount0Input.toUint128(),
            amount1: amount1Input.toUint128(),
            amount0Max: infiPoolParams.amount0Max,
            amount1Max: infiPoolParams.amount1Max,
            activeIdDesired: infiPoolParams.activeIdDesired,
            idSlippage: infiPoolParams.idSlippage,
            deltaIds: infiPoolParams.deltaIds,
            distributionX: infiPoolParams.distributionX,
            distributionY: infiPoolParams.distributionY,
            to: infiPoolParams.to,
            hookData: infiPoolParams.hookData
        });
        (uint256 amount0Consumed, uint256 amount1Consumed) =
            _addLiquidityToTargetPool(addLiquidityParams, infiPoolParams.deadline);

        // refund if necessary, ETH is supported by CurrencyLib
        unchecked {
            if (amount0Input > amount0Consumed) {
                infiPoolParams.poolKey.currency0.transfer(infiPoolParams.to, amount0Input - amount0Consumed);
            }
            if (amount1Input > amount1Consumed) {
                infiPoolParams.poolKey.currency1.transfer(infiPoolParams.to, amount1Input - amount1Consumed);
            }
        }
    }

    /// @dev adding liquidity to target bin pool, collect surplus ETH if necessary
    /// @param params  bin position manager add liquidity params
    /// @param deadline the deadline for the transaction
    /// @return amount0Consumed the actual amount of token0 consumed
    /// @return amount1Consumed the actual amount of token1 consumed
    function _addLiquidityToTargetPool(IBinPositionManager.BinAddLiquidityParams memory params, uint256 deadline)
        internal
        returns (uint128 amount0Consumed, uint128 amount1Consumed)
    {
        /// @dev currency1 cant be NATIVE
        bool nativePair = params.poolKey.currency0.isNative();
        if (!nativePair) {
            permit2ApproveMaxIfNeeded(params.poolKey.currency0, address(binPositionManager), params.amount0);
        }
        permit2ApproveMaxIfNeeded(params.poolKey.currency1, address(binPositionManager), params.amount1);

        uint256 currency0BalanceBefore = params.poolKey.currency0.balanceOfSelf();
        uint256 currency1BalanceBefore = params.poolKey.currency1.balanceOfSelf();

        Plan memory planner = Planner.init();
        planner.add(Actions.BIN_ADD_LIQUIDITY, abi.encode(params));
        planner.add(Actions.SETTLE_PAIR, abi.encode(params.poolKey.currency0, params.poolKey.currency1));
        // need to sweep native token
        if (nativePair) {
            planner.add(Actions.SWEEP, abi.encode(params.poolKey.currency0, ActionConstants.MSG_SENDER));
        }

        binPositionManager.modifyLiquidities{value: nativePair ? params.amount0 : 0}(planner.encode(), deadline);

        uint256 currency0BalanceAfter = params.poolKey.currency0.balanceOfSelf();
        uint256 currency1BalanceAfter = params.poolKey.currency1.balanceOfSelf();

        // If the binPositionManager already holds a balance of native tokens, then currency0BalanceAfter could be greater than currency0BalanceBefore due to the sweep action
        // it means users can get a discount if there is an unexpected native balance in the binPositionManager
        if (currency0BalanceBefore > currency0BalanceAfter) {
            amount0Consumed = (currency0BalanceBefore - currency0BalanceAfter).toUint128();
        }
        // normal tokens will not have this case , but it is better to check
        if (currency1BalanceBefore > currency1BalanceAfter) {
            amount1Consumed = (currency1BalanceBefore - currency1BalanceAfter).toUint128();
        }
    }

    /// @inheritdoc IBinMigrator
    /// @notice Planned to be batched with migration operations through multicall to save gas
    function initializePool(PoolKey memory poolKey, uint24 activeId) external payable override {
        return binPositionManager.initializePool(poolKey, activeId);
    }

    receive() external payable {
        if (msg.sender != address(binPositionManager) && msg.sender != WETH9) {
            revert INVALID_ETHER_SENDER();
        }
    }
}