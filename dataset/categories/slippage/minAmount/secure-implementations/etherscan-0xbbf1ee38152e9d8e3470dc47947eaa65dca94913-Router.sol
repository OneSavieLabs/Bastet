// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "@maverick/contracts/contracts/interfaces/IPool.sol";
import "@maverick/contracts/contracts/interfaces/IFactory.sol";
import "@maverick/contracts/contracts/interfaces/IPosition.sol";

import "./interfaces/IRouter.sol";
import "./interfaces/external/IWETH9.sol";
import "./libraries/TransferHelper.sol";
import "./libraries/Path.sol";
import "./libraries/Deadline.sol";
import "./libraries/Multicall.sol";
import "./libraries/SelfPermit.sol";

contract Router is IRouter, Multicall, SelfPermit, Deadline {
    using Path for bytes;
    /// @dev Used as the placeholder value for amountInCached, because the
    //computed amount in for an exact output swap / can never actually be this
    //value
    uint256 private constant DEFAULT_AMOUNT_IN_CACHED = type(uint256).max;

    /// @dev Transient storage variable used for returning the computed amount in for an exact output swap.
    uint256 private amountInCached = DEFAULT_AMOUNT_IN_CACHED;

    struct AddLiquidityCallbackData {
        IERC20 tokenA;
        IERC20 tokenB;
        IPool pool;
        address payer;
    }

    struct SwapCallbackData {
        bytes path;
        address payer;
        bool exactOutput;
    }

    /// @inheritdoc IRouter
    IFactory public immutable factory;
    /// @inheritdoc IRouter
    IPosition public immutable position;
    /// @inheritdoc ISlimRouter
    IWETH9 public immutable WETH9;

    constructor(IFactory _factory, IWETH9 _WETH9) {
        factory = _factory;
        position = _factory.position();
        WETH9 = _WETH9;
    }

    receive() external payable {
        require(IWETH9(msg.sender) == WETH9, "Not WETH9");
    }

    /// @inheritdoc ISlimRouter
    function unwrapWETH9(uint256 amountMinimum, address recipient) public payable override {
        uint256 balanceWETH9 = WETH9.balanceOf(address(this));
        require(balanceWETH9 >= amountMinimum, "Insufficient WETH9");

        if (balanceWETH9 > 0) {
            WETH9.withdraw(balanceWETH9);
            TransferHelper.safeTransferETH(recipient, balanceWETH9);
        }
    }

    /// @inheritdoc ISlimRouter
    function sweepToken(IERC20 token, uint256 amountMinimum, address recipient) public payable {
        uint256 balanceToken = token.balanceOf(address(this));
        require(balanceToken >= amountMinimum, "Insufficient token");

        if (balanceToken > 0) {
            TransferHelper.safeTransfer(address(token), recipient, balanceToken);
        }
    }

    /// @inheritdoc ISlimRouter
    function refundETH() external payable override {
        if (address(this).balance > 0)
            TransferHelper.safeTransferETH(msg.sender, address(this).balance);
    }

    /// @param token The token to pay
    /// @param payer The entity that must pay
    /// @param recipient The entity that will receive payment
    /// @param value The amount to pay
    function pay(IERC20 token, address payer, address recipient, uint256 value) internal {
        if (IWETH9(address(token)) == WETH9 && address(this).balance >= value) {
            WETH9.deposit{value: value}();
            WETH9.transfer(recipient, value);
        } else if (payer == address(this)) {
            TransferHelper.safeTransfer(address(token), recipient, value);
        } else {
            TransferHelper.safeTransferFrom(address(token), payer, recipient, value);
        }
    }

    function swapCallback(uint256 amountToPay, uint256 amountOut, bytes calldata _data) external {
        require(amountToPay > 0 && amountOut > 0, "In or Out Amount is Zero");
        require(factory.isFactoryPool(IPool(msg.sender)), "Must call from a Factory Pool");

        SwapCallbackData memory data = abi.decode(_data, (SwapCallbackData));
        (IERC20 tokenIn, IERC20 tokenOut, IPool pool) = data.path.decodeFirstPool();

        require(msg.sender == address(pool));

        if (data.exactOutput) {
            if (data.path.hasMultiplePools()) {
                data.path = data.path.skipToken();
                exactOutputInternal(amountToPay, msg.sender, data);
            } else {
                amountInCached = amountToPay;
                pay(tokenOut, data.payer, msg.sender, amountToPay);
            }
        } else {
            pay(tokenIn, data.payer, msg.sender, amountToPay);
        }
    }

    function exactInputInternal(
        uint256 amountIn,
        address recipient,
        uint256 sqrtPriceLimitD18,
        SwapCallbackData memory data
    ) private returns (uint256 amountOut) {
        if (recipient == address(0)) recipient = address(this);

        (IERC20 tokenIn, IERC20 tokenOut, IPool pool) = data.path.decodeFirstPool();

        bool tokenAIn = tokenIn < tokenOut;

        (, amountOut) = pool.swap(
            recipient,
            amountIn,
            tokenAIn,
            false,
            sqrtPriceLimitD18,
            abi.encode(data)
        );
    }

    /// @inheritdoc ISlimRouter
    function exactInputSingle(
        ExactInputSingleParams calldata params
    ) external payable override checkDeadline(params.deadline) returns (uint256 amountOut) {
        bool tokenAIn = params.tokenIn < params.tokenOut;

        (, amountOut) = params.pool.swap(
            (params.recipient == address(0)) ? address(this) : params.recipient,
            params.amountIn,
            tokenAIn,
            false,
            params.sqrtPriceLimitD18,
            abi.encode(
                SwapCallbackData({
                    path: abi.encodePacked(params.tokenIn, params.pool, params.tokenOut),
                    payer: msg.sender,
                    exactOutput: false
                })
            )
        );
        require(amountOut >= params.amountOutMinimum, "Too little received");
    }

    /// @inheritdoc IRouter
    function exactInput(
        ExactInputParams memory params
    ) external payable override checkDeadline(params.deadline) returns (uint256 amountOut) {
        address payer = msg.sender;

        while (true) {
            bool stillMultiPoolSwap = params.path.hasMultiplePools();

            params.amountIn = exactInputInternal(
                params.amountIn,
                stillMultiPoolSwap ? address(this) : params.recipient,
                0,
                SwapCallbackData({
                    path: params.path.getFirstPool(),
                    payer: payer,
                    exactOutput: false
                })
            );

            if (stillMultiPoolSwap) {
                payer = address(this);
                params.path = params.path.skipToken();
            } else {
                amountOut = params.amountIn;
                break;
            }
        }

        require(amountOut >= params.amountOutMinimum, "Too little received");
    }

    /// @dev Performs a single exact output swap
    function exactOutputInternal(
        uint256 amountOut,
        address recipient,
        SwapCallbackData memory data
    ) private returns (uint256 amountIn) {
        if (recipient == address(0)) recipient = address(this);

        (IERC20 tokenOut, IERC20 tokenIn, IPool pool) = data.path.decodeFirstPool();

        bool tokenAIn = tokenIn < tokenOut;
        uint256 amountOutReceived;
        (amountIn, amountOutReceived) = pool.swap(
            recipient,
            amountOut,
            tokenAIn,
            true,
            0,
            abi.encode(data)
        );
        require(amountOutReceived == amountOut, "Requested amount not available");
    }

    /// @inheritdoc ISlimRouter
    function exactOutputSingle(
        ExactOutputSingleParams calldata params
    ) external payable override checkDeadline(params.deadline) returns (uint256 amountIn) {
        bool tokenAIn = params.tokenIn < params.tokenOut;
        uint256 amountOutReceived;
        (amountIn, amountOutReceived) = params.pool.swap(
            (params.recipient == address(0)) ? address(this) : params.recipient,
            params.amountOut,
            tokenAIn,
            true,
            0,
            abi.encode(
                SwapCallbackData({
                    path: abi.encodePacked(params.tokenOut, params.pool, params.tokenIn),
                    payer: msg.sender,
                    exactOutput: true
                })
            )
        );
        require(amountOutReceived == params.amountOut, "Requested amount not available");
        require(amountIn <= params.amountInMaximum, "Too much requested");
        amountInCached = DEFAULT_AMOUNT_IN_CACHED;
    }

    /// @inheritdoc IRouter
    function exactOutput(
        ExactOutputParams calldata params
    ) external payable override checkDeadline(params.deadline) returns (uint256 amountIn) {
        exactOutputInternal(
            params.amountOut,
            params.recipient,
            SwapCallbackData({path: params.path, payer: msg.sender, exactOutput: true})
        );

        amountIn = amountInCached;
        require(amountIn <= params.amountInMaximum, "Too much requested");
        amountInCached = DEFAULT_AMOUNT_IN_CACHED;
    }

    // Liqudity

    function addLiquidityCallback(uint256 amountA, uint256 amountB, bytes calldata _data) external {
        AddLiquidityCallbackData memory data = abi.decode(_data, (AddLiquidityCallbackData));
        require(factory.isFactoryPool(IPool(msg.sender)));
        require(msg.sender == address(data.pool));
        if (amountA != 0) {
            pay(data.tokenA, data.payer, msg.sender, amountA);
        }
        if (amountB != 0) {
            pay(data.tokenB, data.payer, msg.sender, amountB);
        }
    }

    function addLiquidity(
        IPool pool,
        uint256 tokenId,
        IPool.AddLiquidityParams[] calldata params,
        uint256 minTokenAAmount,
        uint256 minTokenBAmount
    )
        private
        returns (
            uint256 receivingTokenId,
            uint256 tokenAAmount,
            uint256 tokenBAmount,
            IPool.BinDelta[] memory binDeltas
        )
    {
        if (tokenId == 0) {
            if (IPosition(position).tokenOfOwnerByIndexExists(msg.sender, 0)) {
                tokenId = IPosition(position).tokenOfOwnerByIndex(msg.sender, 0);
            } else {
                tokenId = IPosition(position).mint(msg.sender);
            }
        }
        receivingTokenId = tokenId;

        AddLiquidityCallbackData memory data = AddLiquidityCallbackData({
            tokenA: pool.tokenA(),
            tokenB: pool.tokenB(),
            pool: pool,
            payer: msg.sender
        });
        (tokenAAmount, tokenBAmount, binDeltas) = pool.addLiquidity(
            tokenId,
            params,
            abi.encode(data)
        );

        require(
            tokenAAmount >= minTokenAAmount && tokenBAmount >= minTokenBAmount,
            "Too little added"
        );
    }

    /// @inheritdoc IRouter
    function addLiquidityToPool(
        IPool pool,
        uint256 tokenId,
        IPool.AddLiquidityParams[] calldata params,
        uint256 minTokenAAmount,
        uint256 minTokenBAmount,
        uint256 deadline
    )
        external
        payable
        checkDeadline(deadline)
        returns (
            uint256 receivingTokenId,
            uint256 tokenAAmount,
            uint256 tokenBAmount,
            IPool.BinDelta[] memory binDeltas
        )
    {
        return addLiquidity(pool, tokenId, params, minTokenAAmount, minTokenBAmount);
    }

    /// @inheritdoc IRouter
    function addLiquidityWTickLimits(
        IPool pool,
        uint256 tokenId,
        IPool.AddLiquidityParams[] calldata params,
        uint256 minTokenAAmount,
        uint256 minTokenBAmount,
        int32 minActiveTick,
        int32 maxActiveTick,
        uint256 deadline
    )
        external
        payable
        checkDeadline(deadline)
        returns (
            uint256 receivingTokenId,
            uint256 tokenAAmount,
            uint256 tokenBAmount,
            IPool.BinDelta[] memory binDeltas
        )
    {
        int32 activeTick = pool.getState().activeTick;

        require(
            activeTick >= minActiveTick && activeTick <= maxActiveTick,
            "activeTick not in range"
        );

        return addLiquidity(pool, tokenId, params, minTokenAAmount, minTokenBAmount);
    }

    function getOrCreatePool(PoolParams calldata poolParams) private returns (IPool pool) {
        {
            pool = IFactory(factory).lookup(
                poolParams.fee,
                poolParams.tickSpacing,
                poolParams.lookback,
                poolParams.tokenA,
                poolParams.tokenB
            );
        }
        if (address(pool) == address(0)) {
            pool = IFactory(factory).create(
                poolParams.fee,
                poolParams.tickSpacing,
                poolParams.lookback,
                poolParams.activeTick,
                poolParams.tokenA,
                poolParams.tokenB
            );
        }
    }

    /// @inheritdoc IRouter
    function getOrCreatePoolAndAddLiquidity(
        PoolParams calldata poolParams,
        uint256 tokenId,
        IPool.AddLiquidityParams[] calldata addParams,
        uint256 minTokenAAmount,
        uint256 minTokenBAmount,
        uint256 deadline
    )
        external
        payable
        checkDeadline(deadline)
        returns (
            uint256 receivingTokenId,
            uint256 tokenAAmount,
            uint256 tokenBAmount,
            IPool.BinDelta[] memory binDeltas
        )
    {
        IPool pool = getOrCreatePool(poolParams);
        return addLiquidity(pool, tokenId, addParams, minTokenAAmount, minTokenBAmount);
    }

    /// @inheritdoc IRouter
    function migrateBinsUpStack(
        IPool pool,
        uint128[] calldata binIds,
        uint32 maxRecursion,
        uint256 deadline
    ) external checkDeadline(deadline) {
        for (uint256 i = 0; i < binIds.length; i++) {
            pool.migrateBinUpStack(binIds[i], maxRecursion);
        }
    }

    /// @inheritdoc IRouter
    function removeLiquidity(
        IPool pool,
        address recipient,
        uint256 tokenId,
        IPool.RemoveLiquidityParams[] calldata params,
        uint256 minTokenAAmount,
        uint256 minTokenBAmount,
        uint256 deadline
    )
        external
        checkDeadline(deadline)
        returns (uint256 tokenAAmount, uint256 tokenBAmount, IPool.BinDelta[] memory binDeltas)
    {
        require(msg.sender == position.ownerOf(tokenId), "P");

        if (recipient == address(0)) recipient = address(this);
        (tokenAAmount, tokenBAmount, binDeltas) = pool.removeLiquidity(recipient, tokenId, params);

        require(
            tokenAAmount >= minTokenAAmount && tokenBAmount >= minTokenBAmount,
            "Too little removed"
        );
    }
}