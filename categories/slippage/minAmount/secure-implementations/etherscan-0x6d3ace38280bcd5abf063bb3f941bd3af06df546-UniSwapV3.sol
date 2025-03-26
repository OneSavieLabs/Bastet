// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.7.6;
pragma experimental ABIEncoderV2;

import "./BaseSwap.sol";
import "../libraries/BytesLib.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@kyber.network/utils-sc/contracts/IERC20Ext.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IPeripheryImmutableState.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IMulticall.sol";
import "@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/libraries/BitMath.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-core/contracts/libraries/SwapMath.sol";
import "@uniswap/v3-core/contracts/libraries/LiquidityMath.sol";

interface ISwapRouterInternal is ISwapRouter, IMulticall, IPeripheryImmutableState {}

library TickBitmap {
    function position(int24 tick) private pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(tick >> 8);
        bitPos = uint8(tick % 256);
    }

    function nextInitializedTickWithinOneWord(
        IUniswapV3Pool pool,
        int24 tick,
        int24 tickSpacing,
        bool lte
    ) internal view returns (int24 next, bool initialized) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--; // round towards negative infinity

        if (lte) {
            (int16 wordPos, uint8 bitPos) = position(compressed);
            // all the 1s at or to the right of the current bitPos
            uint256 mask = (1 << bitPos) - 1 + (1 << bitPos);
            uint256 masked = pool.tickBitmap(wordPos) & mask;

            // if there are no initialized ticks to the right of or at the current tick, return rightmost in the word
            initialized = masked != 0;
            // overflow/underflow is possible, but prevented externally by limiting both tickSpacing and tick
            next = initialized
                ? (compressed - int24(bitPos - BitMath.mostSignificantBit(masked))) * tickSpacing
                : (compressed - int24(bitPos)) * tickSpacing;
        } else {
            // start from the word of the next tick, since the current tick state doesn't matter
            (int16 wordPos, uint8 bitPos) = position(compressed + 1);
            // all the 1s at or to the left of the bitPos
            uint256 mask = ~((1 << bitPos) - 1);
            uint256 masked = pool.tickBitmap(wordPos) & mask;

            // if there are no initialized ticks to the left of the current tick, return leftmost in the word
            initialized = masked != 0;
            // overflow/underflow is possible, but prevented externally by limiting both tickSpacing and tick
            next = initialized
                ? (compressed + 1 + int24(BitMath.leastSignificantBit(masked) - bitPos)) *
                    tickSpacing
                : (compressed + 1 + int24(type(uint8).max - bitPos)) * tickSpacing;
        }
    }
}

/// General swap for uniswap v3 and its clones
contract UniSwapV3 is BaseSwap {
    using SafeERC20 for IERC20Ext;
    using Address for address;
    using EnumerableSet for EnumerableSet.AddressSet;
    using BytesLib for bytes;
    using SafeCast for uint256;
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for int256;
    using TickBitmap for IUniswapV3Pool;

    EnumerableSet.AddressSet private uniRouters;

    event UpdatedUniRouters(ISwapRouterInternal[] routers, bool isSupported);

    constructor(address _admin, ISwapRouterInternal[] memory routers) BaseSwap(_admin) {
        for (uint256 i = 0; i < routers.length; i++) {
            uniRouters.add(address(routers[i]));
        }
    }

    struct StepComputations {
        // the price at the beginning of the step
        uint160 sqrtPriceStartX96;
        // the next tick to swap to from the current tick in the swap direction
        int24 tickNext;
        // whether tickNext is initialized or not
        bool initialized;
        // sqrt(price) for the next tick (1/0)
        uint160 sqrtPriceNextX96;
        // how much is being swapped in in this step
        uint256 amountIn;
        // how much is being swapped out
        uint256 amountOut;
        // how much fee is being paid in
        uint256 feeAmount;
    }

    struct SwapState {
        // the amount remaining to be swapped in/out of the input/output asset
        int256 amountSpecifiedRemaining;
        // the amount already swapped out/in of the output/input asset
        int256 amountCalculated;
        // current sqrt(price)
        uint160 sqrtPriceX96;
        // the tick associated with the current price
        int24 tick;
        // the current liquidity in range
        uint128 liquidity;
    }

    function getAllUniRouters() external view returns (address[] memory addresses) {
        uint256 length = uniRouters.length();
        addresses = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            addresses[i] = uniRouters.at(i);
        }
    }

    function updateUniRouters(ISwapRouterInternal[] calldata routers, bool isSupported)
        external
        onlyAdmin
    {
        for (uint256 i = 0; i < routers.length; i++) {
            if (isSupported) {
                uniRouters.add(address(routers[i]));
            } else {
                uniRouters.remove(address(routers[i]));
            }
        }
        emit UpdatedUniRouters(routers, isSupported);
    }

    /// @dev get expected return and conversion rate if using a Uni router
    function getExpectedReturn(GetExpectedReturnParams calldata params)
        external
        view
        override
        onlyProxyContract
        returns (uint256 destAmount)
    {
        require(params.tradePath.length >= 2, "invalid tradePath");
        (ISwapRouterInternal router, uint24[] memory fees) = parseExtraArgs(
            params.tradePath.length - 1,
            params.extraArgs
        );

        destAmount = params.srcAmount;
        for (uint256 i = 0; i < params.tradePath.length - 1; i++) {
            destAmount = getAmountOut(
                router,
                destAmount,
                params.tradePath[i],
                params.tradePath[i + 1],
                fees[i]
            );
        }
    }

    /// @dev get expected return and conversion rate if using a Uni router
    function getExpectedReturnWithImpact(GetExpectedReturnParams calldata params)
        external
        view
        override
        onlyProxyContract
        returns (uint256 destAmount, uint256 priceImpact)
    {
        require(params.tradePath.length >= 2, "invalid tradePath");
        (ISwapRouterInternal router, uint24[] memory fees) = parseExtraArgs(
            params.tradePath.length - 1,
            params.extraArgs
        );

        destAmount = params.srcAmount;
        uint256 quote = params.srcAmount;
        for (uint256 i = 0; i < params.tradePath.length - 1; i++) {
            destAmount = getAmountOut(
                router,
                destAmount,
                params.tradePath[i],
                params.tradePath[i + 1],
                fees[i]
            );
            quote = getQuote(router, quote, params.tradePath[i], params.tradePath[i + 1], fees[i]);
        }
        if (quote <= destAmount) {
            priceImpact = 0;
        } else {
            priceImpact = quote.sub(destAmount).mul(BPS) / quote;
        }
    }

    function getExpectedIn(GetExpectedInParams calldata params)
        external
        view
        override
        onlyProxyContract
        returns (uint256 srcAmount)
    {
        require(params.tradePath.length >= 2, "invalid tradePath");
        (ISwapRouterInternal router, uint24[] memory fees) = parseExtraArgs(
            params.tradePath.length - 1,
            params.extraArgs
        );

        srcAmount = params.destAmount;
        for (uint256 i = params.tradePath.length - 1; i > 0; i--) {
            srcAmount = getAmountIn(
                router,
                srcAmount,
                params.tradePath[i - 1],
                params.tradePath[i],
                fees[i - 1]
            );
        }
    }

    function getExpectedInWithImpact(GetExpectedInParams calldata params)
        external
        view
        override
        onlyProxyContract
        returns (uint256 srcAmount, uint256 priceImpact)
    {
        require(params.tradePath.length >= 2, "invalid tradePath");
        (ISwapRouterInternal router, uint24[] memory fees) = parseExtraArgs(
            params.tradePath.length - 1,
            params.extraArgs
        );

        srcAmount = params.destAmount;
        for (uint256 i = params.tradePath.length - 1; i > 0; i--) {
            srcAmount = getAmountIn(
                router,
                srcAmount,
                params.tradePath[i - 1],
                params.tradePath[i],
                fees[i - 1]
            );
        }
        uint256 quote = srcAmount;
        for (uint256 i = 0; i < params.tradePath.length - 1; i++) {
            quote = getQuote(router, quote, params.tradePath[i], params.tradePath[i + 1], fees[i]);
        }
        if (quote <= params.destAmount) {
            priceImpact = 0;
        } else {
            priceImpact = quote.sub(params.destAmount).mul(BPS) / quote;
        }
    }

    /// @dev swap token via a supported UniSwap router
    /// @notice for some tokens that are paying fee, for example: DGX
    /// contract will trade with received src token amount (after minus fee)
    /// for UniSwap, fee will be taken in src token
    function swap(SwapParams calldata params)
        external
        payable
        override
        onlyProxyContract
        returns (uint256 destAmount)
    {
        require(params.tradePath.length >= 2, "invalid tradePath");

        (ISwapRouterInternal router, uint24[] memory fees) = parseExtraArgs(
            params.tradePath.length - 1,
            params.extraArgs
        );

        safeApproveAllowance(address(router), IERC20Ext(params.tradePath[0]));

        destAmount = getBalance(
            IERC20Ext(params.tradePath[params.tradePath.length - 1]),
            params.recipient
        );

        // actual swap
        if (params.tradePath.length == 2) {
            swapExactInputSingle(
                router,
                params.srcAmount,
                params.minDestAmount,
                params.tradePath,
                fees,
                params.recipient
            );
        } else {
            swapExactInput(
                router,
                params.srcAmount,
                params.minDestAmount,
                params.tradePath,
                fees,
                params.recipient
            );
        }

        destAmount = getBalance(
            IERC20Ext(params.tradePath[params.tradePath.length - 1]),
            params.recipient
        ).sub(destAmount);
    }

    function swapExactInput(
        ISwapRouterInternal router,
        uint256 srcAmount,
        uint256 minDestAmount,
        address[] calldata tradePath,
        uint24[] memory fees,
        address recipient
    ) internal {
        bytes memory path = abi.encodePacked(safeWrapToken(tradePath[0], router.WETH9()));
        for (uint256 i = 0; i < fees.length; i++) {
            path = abi.encodePacked(
                path,
                fees[i],
                safeWrapToken(tradePath[i + 1], router.WETH9())
            );
        }
        ISwapRouter.ExactInputParams memory swapData = ISwapRouter.ExactInputParams({
            path: path,
            recipient: recipient,
            deadline: MAX_AMOUNT,
            amountIn: srcAmount,
            amountOutMinimum: minDestAmount
        });

        if (tradePath[tradePath.length - 1] == address(ETH_TOKEN_ADDRESS)) {
            swapData.recipient = address(0);
            bytes[] memory multicallData = new bytes[](2);
            multicallData[0] = abi.encodeWithSelector(
                0xc04b8d59, // exactInput
                swapData
            );
            multicallData[1] = abi.encodeWithSelector(
                0x49404b7c, // unwrapWETH9
                minDestAmount,
                recipient
            );
            router.multicall(multicallData);
        } else {
            router.exactInput{value: tradePath[0] == address(ETH_TOKEN_ADDRESS) ? srcAmount : 0}(
                swapData
            );
        }
    }

    function swapExactInputSingle(
        ISwapRouterInternal router,
        uint256 srcAmount,
        uint256 minDestAmount,
        address[] memory tradePath,
        uint24[] memory fees,
        address recipient
    ) internal {
        ISwapRouter.ExactInputSingleParams memory swapData = ISwapRouter.ExactInputSingleParams({
            tokenIn: safeWrapToken(tradePath[0], router.WETH9()),
            tokenOut: safeWrapToken(tradePath[1], router.WETH9()),
            fee: fees[0],
            recipient: recipient,
            deadline: MAX_AMOUNT,
            amountIn: srcAmount,
            amountOutMinimum: minDestAmount,
            sqrtPriceLimitX96: 0
        });

        if (tradePath[tradePath.length - 1] == address(ETH_TOKEN_ADDRESS)) {
            swapData.recipient = address(0);
            bytes[] memory multicallData = new bytes[](2);
            multicallData[0] = abi.encodeWithSelector(
                0x414bf389, // exactInputSingle
                swapData
            );
            multicallData[1] = abi.encodeWithSelector(
                0x49404b7c, // unwrapWETH9
                minDestAmount,
                recipient
            );
            router.multicall(multicallData);
        } else {
            router.exactInputSingle{
                value: tradePath[0] == address(ETH_TOKEN_ADDRESS) ? srcAmount : 0
            }(swapData);
        }
    }

    /// @param extraArgs expecting <[20B] address router><[3B] uint24 poolFee1><[3B] uint24 poolFee2>...
    function parseExtraArgs(uint256 feeLength, bytes calldata extraArgs)
        internal
        view
        returns (ISwapRouterInternal router, uint24[] memory fees)
    {
        fees = new uint24[](feeLength);
        router = ISwapRouterInternal(extraArgs.toAddress(0));
        for (uint256 i = 0; i < feeLength; i++) {
            fees[i] = extraArgs.toUint24(20 + i * 3);
        }
        require(router != ISwapRouterInternal(0), "invalid address");
        require(uniRouters.contains(address(router)), "unsupported router");
    }

    function getAmountOut(
        ISwapRouterInternal router,
        uint256 amountIn,
        address tokenIn,
        address tokenOut,
        uint24 fee
    ) private view returns (uint256 amountOut) {
        return getAmount(router, amountIn.toInt256(), tokenIn, tokenOut, fee);
    }

    function getAmountIn(
        ISwapRouterInternal router,
        uint256 amountOut,
        address tokenIn,
        address tokenOut,
        uint24 fee
    ) private view returns (uint256 amountIn) {
        return getAmount(router, -amountOut.toInt256(), tokenIn, tokenOut, fee);
    }

    function getAmount(
        ISwapRouterInternal router,
        int256 amountSpecified,
        address tokenIn,
        address tokenOut,
        uint24 fee
    ) private view returns (uint256 amountOut) {
        IUniswapV3Pool pool = IUniswapV3Pool(
            PoolAddress.computeAddress(
                router.factory(),
                PoolAddress.getPoolKey(tokenIn, tokenOut, fee)
            )
        );

        int24 tickSpacing = pool.tickSpacing();

        // if tokenIn == tokenOut
        bool zeroForOne = tokenIn < tokenOut;
        uint160 sqrtPriceLimitX96 = zeroForOne
            ? TickMath.MIN_SQRT_RATIO + 1
            : TickMath.MAX_SQRT_RATIO - 1;

        SwapState memory state;
        state.amountSpecifiedRemaining = amountSpecified;
        state.amountCalculated = 0;
        (state.sqrtPriceX96, state.tick, , , , , ) = pool.slot0();
        state.liquidity = pool.liquidity();
        bool exactInput = amountSpecified > 0;

        while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
            StepComputations memory step;

            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            (step.tickNext, step.initialized) = pool.nextInitializedTickWithinOneWord(
                state.tick,
                tickSpacing,
                zeroForOne
            );

            if (step.tickNext < TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            } else if (step.tickNext > TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);

            (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath
            .computeSwapStep(
                state.sqrtPriceX96,
                (
                    zeroForOne
                        ? step.sqrtPriceNextX96 < sqrtPriceLimitX96
                        : step.sqrtPriceNextX96 > sqrtPriceLimitX96
                )
                    ? sqrtPriceLimitX96
                    : step.sqrtPriceNextX96,
                state.liquidity,
                state.amountSpecifiedRemaining,
                fee
            );

            if (exactInput) {
                state.amountSpecifiedRemaining -= (step.amountIn + step.feeAmount).toInt256();
                state.amountCalculated = state.amountCalculated.sub(step.amountOut.toInt256());
            } else {
                state.amountSpecifiedRemaining += step.amountOut.toInt256();
                state.amountCalculated = state.amountCalculated.add(
                    (step.amountIn + step.feeAmount).toInt256()
                );
            }

            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                if (step.initialized) {
                    (, int128 liquidityNet, , , , , , ) = pool.ticks(step.tickNext);

                    if (zeroForOne) liquidityNet = -liquidityNet;
                    state.liquidity = LiquidityMath.addDelta(state.liquidity, liquidityNet);
                }
                state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }

        if (state.amountCalculated < 0) {
            return uint256(-state.amountCalculated);
        }
        return uint256(state.amountCalculated);
    }

    function getQuote(
        ISwapRouterInternal router,
        uint256 quote,
        address tokenIn,
        address tokenOut,
        uint24 fee
    ) internal view returns (uint256 quoteOut) {
        IUniswapV3Pool pool = IUniswapV3Pool(
            PoolAddress.computeAddress(
                router.factory(),
                PoolAddress.getPoolKey(tokenIn, tokenOut, fee)
            )
        );

        // if tokenIn == tokenOut
        bool zeroForOne = tokenIn < tokenOut;
        SwapState memory state;
        (state.sqrtPriceX96, state.tick, , , , , ) = pool.slot0();
        uint160 sqrtPriceX96 = zeroForOne
            ? state.sqrtPriceX96
            : TickMath.getSqrtRatioAtTick(-state.tick);
        quoteOut = quote.mul(sqrtPriceX96) >> 96;
        quoteOut = quoteOut.mul(sqrtPriceX96) >> 96;
    }

    function safeWrapToken(address token, address wrappedToken) internal pure returns (address) {
        return token == address(ETH_TOKEN_ADDRESS) ? wrappedToken : token;
    }
}