// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity 0.8.26;

import {TickMath} from ""infinity-core/src/pool-cl/libraries/TickMath.sol"";
import {PoolIdLibrary} from ""infinity-core/src/types/PoolId.sol"";
import {SqrtPriceMath} from ""infinity-core/src/pool-cl/libraries/SqrtPriceMath.sol"";
import {BaseMigrator, IV3NonfungiblePositionManager} from ""../base/BaseMigrator.sol"";
import {ICLMigrator, PoolKey} from ""./interfaces/ICLMigrator.sol"";
import {ICLPoolManager} from ""infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol"";
import {IAllowanceTransfer} from ""permit2/src/interfaces/IAllowanceTransfer.sol"";
import {LiquidityAmounts} from ""./libraries/LiquidityAmounts.sol"";
import {ICLPositionManager} from ""./interfaces/ICLPositionManager.sol"";
import {Actions} from ""../libraries/Actions.sol"";
import {Plan, Planner} from ""../libraries/Planner.sol"";
import {ReentrancyLock} from ""../base/ReentrancyLock.sol"";

contract CLMigrator is ICLMigrator, BaseMigrator, ReentrancyLock {
    ICLPositionManager public immutable clPositionManager;
    ICLPoolManager public immutable clPoolManager;

    constructor(address _WETH9, address _clPositionManager, IAllowanceTransfer _permit2)
        BaseMigrator(_WETH9, _clPositionManager, _permit2)
    {
        clPositionManager = ICLPositionManager(_clPositionManager);
        clPoolManager = clPositionManager.clPoolManager();
    }

    /// @inheritdoc ICLMigrator
    function migrateFromV2(
        V2PoolParams calldata v2PoolParams,
        InfiCLPoolParams calldata infiPoolParams,
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

        uint256 amount0In = amount0Received + extraAmount0;
        uint256 amount1In = amount1Received + extraAmount1;
        MintParams memory mintParams = MintParams({
            poolKey: infiPoolParams.poolKey,
            tickLower: infiPoolParams.tickLower,
            tickUpper: infiPoolParams.tickUpper,
            amount0In: uint128(amount0In),
            amount1In: uint128(amount1In),
            liquidityMin: infiPoolParams.liquidityMin,
            recipient: infiPoolParams.recipient,
            hookData: infiPoolParams.hookData
        });
        (uint256 amount0Consumed, uint256 amount1Consumed) =
            _addLiquidityToTargetPool(mintParams, infiPoolParams.deadline);

        // refund if necessary, ETH is supported by CurrencyLib
        unchecked {
            if (amount0In > amount0Consumed) {
                infiPoolParams.poolKey.currency0.transfer(infiPoolParams.recipient, amount0In - amount0Consumed);
            }
            if (amount1In > amount1Consumed) {
                infiPoolParams.poolKey.currency1.transfer(infiPoolParams.recipient, amount1In - amount1Consumed);
            }
        }
    }

    /// @inheritdoc ICLMigrator
    function migrateFromV3(
        V3PoolParams calldata v3PoolParams,
        InfiCLPoolParams calldata infiPoolParams,
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

        uint256 amount0In = amount0Received + extraAmount0;
        uint256 amount1In = amount1Received + extraAmount1;
        MintParams memory mintParams = MintParams({
            poolKey: infiPoolParams.poolKey,
            tickLower: infiPoolParams.tickLower,
            tickUpper: infiPoolParams.tickUpper,
            amount0In: uint128(amount0In),
            amount1In: uint128(amount1In),
            liquidityMin: infiPoolParams.liquidityMin,
            recipient: infiPoolParams.recipient,
            hookData: infiPoolParams.hookData
        });
        (uint256 amount0Consumed, uint256 amount1Consumed) =
            _addLiquidityToTargetPool(mintParams, infiPoolParams.deadline);

        // refund if necessary, ETH is supported by CurrencyLib
        unchecked {
            if (amount0In > amount0Consumed) {
                infiPoolParams.poolKey.currency0.transfer(infiPoolParams.recipient, amount0In - amount0Consumed);
            }
            if (amount1In > amount1Consumed) {
                infiPoolParams.poolKey.currency1.transfer(infiPoolParams.recipient, amount1In - amount1Consumed);
            }
        }
    }

    /// @dev adding liquidity to target cl pool, collect surplus ETH if necessary
    /// @param params cl position manager add liquidity params
    /// @param deadline the deadline for the transaction
    /// @return amount0Consumed the actual amount of token0 consumed
    /// @return amount1Consumed the actual amount of token1 consumed
    function _addLiquidityToTargetPool(MintParams memory params, uint256 deadline)
        internal
        returns (uint256 amount0Consumed, uint256 amount1Consumed)
    {
        /// @dev currency1 cant be NATIVE
        bool nativePair = params.poolKey.currency0.isNative();
        if (!nativePair) {
            permit2ApproveMaxIfNeeded(params.poolKey.currency0, address(clPositionManager), params.amount0In);
        }
        permit2ApproveMaxIfNeeded(params.poolKey.currency1, address(clPositionManager), params.amount1In);

        (uint160 sqrtPriceX96, int24 activeTick,,) = clPoolManager.getSlot0(params.poolKey.toId());
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(params.tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(params.tickUpper);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, params.amount0In, params.amount1In
        );

        if (liquidity < params.liquidityMin) {
            revert INSUFFICIENT_LIQUIDITY();
        }

        // Calculate amt0/amt1 from liquidity, similar to CLPool modifyLiquidity logic
        if (activeTick < params.tickLower) {
            amount0Consumed = SqrtPriceMath.getAmount0Delta(sqrtRatioAX96, sqrtRatioBX96, liquidity, true);
        } else if (activeTick < params.tickUpper) {
            amount0Consumed = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtRatioBX96, liquidity, true);
            amount1Consumed = SqrtPriceMath.getAmount1Delta(sqrtRatioAX96, sqrtPriceX96, liquidity, true);
        } else {
            amount1Consumed = SqrtPriceMath.getAmount1Delta(sqrtRatioAX96, sqrtPriceX96, liquidity, true);
        }

        Plan memory planner = Planner.init();
        planner.add(
            Actions.CL_MINT_POSITION,
            abi.encode(
                params.poolKey,
                params.tickLower,
                params.tickUpper,
                uint256(liquidity),
                params.amount0In,
                params.amount1In,
                params.recipient,
                params.hookData
            )
        );
        bytes memory lockData = planner.finalizeModifyLiquidityWithSettlePair(params.poolKey);

        clPositionManager.modifyLiquidities{value: nativePair ? amount0Consumed : 0}(lockData, deadline);
    }

    /// @inheritdoc ICLMigrator
    /// @notice Planned to be batched with migration operations through multicall to save gas
    function initializePool(PoolKey memory poolKey, uint160 sqrtPriceX96)
        external
        payable
        override
        returns (int24 tick)
    {
        return clPositionManager.initializePool(poolKey, sqrtPriceX96);
    }

    receive() external payable {
        if (msg.sender != address(clPositionManager) && msg.sender != WETH9) {
            revert INVALID_ETHER_SENDER();
        }
    }
}