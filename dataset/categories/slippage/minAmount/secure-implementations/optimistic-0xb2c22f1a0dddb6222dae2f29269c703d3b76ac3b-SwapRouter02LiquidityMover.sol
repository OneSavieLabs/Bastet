// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.15; // TODO: Forced this because IWETH9 required 0.8.15.

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { TransferHelper } from "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import { IV3SwapRouter } from "@uniswap/swap-router-contracts/contracts/interfaces/IV3SwapRouter.sol";
import { IPeripheryImmutableState } from "@uniswap/v3-periphery/contracts/interfaces/IPeripheryImmutableState.sol";
import { IWETH9 } from "@uniswap/v3-periphery/contracts/interfaces/external/IWETH9.sol";

import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperToken.sol";
import { ISETHCustom, ISETH } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/tokens/ISETH.sol";

import {
    IUniswapSwapRouter,
    Torex,
    ITwapObserver,
    IUniswapV3PoolTwapObserver,
    TorexConfig,
    ILiquidityMover
} from "./ILiquidityMover.sol";

contract SwapRouter02LiquidityMover is ILiquidityMover {
    uint8 private constant SUPERTOKEN_DECIMALS = 18;

    IUniswapSwapRouter public immutable swapRouter;
    IWETH9 public immutable WETH;
    ISETH public immutable SETH;
    IERC20 public immutable ERC20ETH;

    enum SuperTokenType {
        Pure,
        Wrapper,
        NativeAsset
    }

    struct Context {
        Torex torex;
        bytes swapPath;
        ITwapObserver observer;
        ISuperToken inToken;
        ISuperToken outToken;
        IERC20 swapInToken;
        uint256 swapInAmount;
        SuperTokenType outTokenType;
        uint256 outAmountAdjusted;
        IERC20 swapOutToken;
        uint256 swapOutAmountMinimum;
        uint256 swapOutAmountReceived;
        uint256 outAmountActual;
        address rewardAddress;
        uint256 rewardAmountMinimum;
        uint256 rewardAmount;
    }

    event LiquidityMoverFinished(
        address indexed torex,
        address indexed rewardAddress,
        address inToken,
        uint256 inAmount,
        address outToken,
        uint256 minOutAmount,
        uint256 outAmountActual,
        uint256 rewardAmount
    );

    /**
     * @param _swapRouter02 Make sure it's "SwapRouter02"!!! Not just "SwapRouter".
     * @param _nativeAssetSuperToken The chain's Native Asset Super Token (aka ETHx or SETH).
     * @param _nativeAssetERC20 The chain's ERC20 for Native Asset (not necessarily WETH).
     */
    constructor(
        IUniswapSwapRouter _swapRouter02,
        // Uniswap addresses available here: https://docs.uniswap.org/contracts/v3/reference/deployments (e.g.
        // 0xE592427A0AEce92De3Edee1F18E0157C05861564 for swap router)
        ISETH _nativeAssetSuperToken,
        IERC20 _nativeAssetERC20
    ) {
        swapRouter = _swapRouter02;
        SETH = _nativeAssetSuperToken;

        ERC20ETH = _nativeAssetERC20;
        WETH = IWETH9(_swapRouter02.WETH9());
        // Note that native asset ERC20 usage will take priority over WETH when handling Native Asset Super Tokens.

        if (address(ERC20ETH) == address(0) && address(WETH) == address(0)) {
            revert("LiquidityMover: Don't know how to handle native asset ERC20.");
        }
    }

    receive() external payable { }

    function moveLiquidity(Torex torex) external {
        _moveLiquidity(torex, address(0), 0, bytes(""));
    }

    function moveLiquidityWithPath(Torex torex, bytes calldata swapPath) external {
        _moveLiquidity(torex, address(0), 0, swapPath);
    }

    function moveLiquidityForReward(Torex torex) external {
        _moveLiquidity(torex, msg.sender, 0, bytes(""));
    }

    function moveLiquidityForReward(Torex torex, uint256 rewardAmountMinimum) external {
        _moveLiquidity(torex, msg.sender, rewardAmountMinimum, bytes(""));
    }

    function moveLiquidityForReward(Torex torex, address rewardAddress) external {
        _moveLiquidity(torex, rewardAddress, 0, bytes(""));
    }

    function moveLiquidityForReward(Torex torex, address rewardAddress, uint256 rewardAmountMinimum) external {
        _moveLiquidity(torex, rewardAddress, rewardAmountMinimum, bytes(""));
    }

    function moveLiquidityForRewardWithPath(Torex torex, bytes calldata swapPath) external {
        _moveLiquidity(torex, msg.sender, 0, swapPath);
    }

    function moveLiquidityForRewardWithPath(
        Torex torex,
        uint256 rewardAmountMinimum,
        bytes calldata swapPath
    )
        external
    {
        _moveLiquidity(torex, msg.sender, rewardAmountMinimum, swapPath);
    }

    function moveLiquidityForRewardWithPath(Torex torex, address rewardAddress, bytes calldata swapPath) external {
        _moveLiquidity(torex, rewardAddress, 0, swapPath);
    }

    function moveLiquidityForRewardWithPath(
        Torex torex,
        address rewardAddress,
        uint256 rewardAmountMinimum,
        bytes calldata swapPath
    )
        external
    {
        _moveLiquidity(torex, rewardAddress, rewardAmountMinimum, swapPath);
    }

    function _moveLiquidity(
        Torex torex,
        address rewardAddress,
        uint256 rewardAmountMinimum,
        bytes memory swapPath
    )
        private
    {
        Context memory ctx = _initializeContext(torex, rewardAddress, rewardAmountMinimum, swapPath);
        torex.moveLiquidity(abi.encode(ctx));
    }

    function moveLiquidityCallback(
        ISuperToken, /* inToken */
        ISuperToken, /* outToken */
        uint256 inAmount,
        uint256 minOutAmount,
        bytes calldata moverData
    )
        external
        override
        returns (bool)
    {
        // TOREX passes the context back (which we passed in through one of the above external functions)
        // through the `moverData`.
        // Note that we do not deem necessary to validate the integrity of the data.
        Context memory ctx = abi.decode(moverData, (Context));

        // # Prepare In and Out Tokens
        // It means unwrapping and converting them to ERC-20s that the swap router understands.
        (ctx.swapInToken, ctx.swapInAmount) = _prepareInTokenForSwap(ctx.inToken, inAmount);
        (ctx.outTokenType, ctx.swapOutToken, ctx.swapOutAmountMinimum) =
            _prepareOutTokenForSwap(ctx.outToken, minOutAmount);

        // # Swap
        // Give swap router maximum allowance if necessary.
        if (ctx.swapInToken.allowance(address(this), address(swapRouter)) < ctx.swapInAmount) {
            TransferHelper.safeApprove(address(ctx.swapInToken), address(swapRouter), type(uint256).max);
        }

        // Set default swap path if not specified explicitly.
        if (ctx.swapPath.length == 0) {
            require(
                ctx.observer.getTypeId() == keccak256("UniswapV3PoolTwapObserver"),
                "LiquidityMover: when trade path is not provided, observer must be a UniswapV3PoolTwapObserver to determine the default swap path."
            );
            ctx.swapPath = abi.encodePacked(
                address(ctx.swapInToken),
                IUniswapV3PoolTwapObserver(address(ctx.observer)).uniPool().fee(),
                address(ctx.swapOutToken)
            );
        }

        // Single swap guide about Swap Router: https://docs.uniswap.org/contracts/v3/guides/swaps/single-swaps
        IV3SwapRouter.ExactInputParams memory params = IV3SwapRouter.ExactInputParams({
            path: ctx.swapPath,
            recipient: address(this),
            amountIn: ctx.swapInAmount,
            amountOutMinimum: ctx.swapOutAmountMinimum
        });

        ctx.swapOutAmountReceived = swapRouter.exactInput(params);

        // # Pay
        if (ctx.rewardAddress == address(0)) {
            // Update all the tokens directly to TOREX.
            ctx.outAmountActual = _upgradeAllTokensToOutTokensIfNecessary(
                ctx.swapOutToken, ctx.outToken, ctx.outTokenType, address(ctx.torex)
            );
        } else {
            // Upgrade tokens here.
            uint256 outTokenBalance =
                _upgradeAllTokensToOutTokensIfNecessary(ctx.swapOutToken, ctx.outToken, ctx.outTokenType, address(this));

            // Send minimum needed amount to TOREX.
            ctx.outAmountActual = minOutAmount;
            TransferHelper.safeTransfer(address(ctx.outToken), address(ctx.torex), ctx.outAmountActual);

            // Everything not sent to TOREX is considered as reward.
            ctx.rewardAmount = outTokenBalance - ctx.outAmountActual;
            require(ctx.rewardAmount >= ctx.rewardAmountMinimum, "LiquidityMover: reward too low");

            if (ctx.rewardAmount > 0) {
                TransferHelper.safeTransfer(address(ctx.outToken), ctx.rewardAddress, ctx.rewardAmount);
            }
        }

        emit LiquidityMoverFinished(
            address(ctx.torex),
            ctx.rewardAddress,
            address(ctx.inToken),
            inAmount,
            address(ctx.outToken),
            minOutAmount,
            ctx.outAmountActual,
            ctx.rewardAmount
        );

        return true;
    }

    function _initializeContext(
        Torex torex,
        address rewardAddress,
        uint256 rewardAmountMinimum,
        bytes memory swapPath
    )
        internal
        view
        returns (Context memory ctx)
    {
        ctx.torex = torex;
        ctx.rewardAddress = rewardAddress;
        ctx.rewardAmountMinimum = rewardAmountMinimum;
        ctx.swapPath = swapPath;

        TorexConfig memory torexConfig = ctx.torex.getConfig();

        ctx.observer = ITwapObserver(address(torexConfig.observer));

        ctx.inToken = torexConfig.inToken;
        ctx.outToken = torexConfig.outToken;
    }

    function _prepareInTokenForSwap(
        ISuperToken inToken,
        uint256 inAmount
    )
        private
        returns (IERC20 swapInToken, uint256 swapInAmount)
    {
        uint256 inTokenBalance = inToken.balanceOf(address(this));
        assert(inTokenBalance >= inAmount); // We always expect the inAmount to be transferred to this contract.

        (SuperTokenType inTokenType, address inTokenUnderlyingToken) = _getSuperTokenType(inToken);
        if (inTokenType == SuperTokenType.Wrapper) {
            inToken.downgrade(inTokenBalance);
            // Note that this can leave some dust behind when underlying token decimals differ.
            swapInToken = IERC20(inTokenUnderlyingToken);
        } else if (inTokenType == SuperTokenType.NativeAsset) {
            ISETH(address(inToken)).downgradeToETH(inTokenBalance);
            if (address(WETH) != address(0)) {
                WETH.deposit{ value: address(this).balance }();
                swapInToken = WETH;
            } else {
                swapInToken = ERC20ETH;
            }
        } else {
            // Pure Super Token
            swapInToken = inToken;
        }
        swapInAmount = swapInToken.balanceOf(address(this));
    }

    function _prepareOutTokenForSwap(
        ISuperToken outToken,
        uint256 outAmount
    )
        private
        view
        returns (SuperTokenType outTokenType, IERC20 swapOutToken, uint256 swapOutAmountMinimum)
    {
        address outTokenUnderlyingToken;
        (outTokenType, outTokenUnderlyingToken) = _getSuperTokenType(outToken);

        if (outTokenType == SuperTokenType.Wrapper) {
            swapOutToken = IERC20(outTokenUnderlyingToken);
            uint256 outAmountRoundedUp = _roundUpOutAmount(outAmount, outToken.getUnderlyingDecimals());
            (swapOutAmountMinimum,) = outToken.toUnderlyingAmount(outAmountRoundedUp);
        } else if (outTokenType == SuperTokenType.NativeAsset) {
            if (address(WETH) != address(0)) {
                swapOutToken = WETH;
            } else {
                swapOutToken = ERC20ETH;
            }
            swapOutAmountMinimum = outAmount;
        } else {
            // Pure Super Token
            swapOutToken = outToken;
            swapOutAmountMinimum = outAmount;
        }
    }

    function _upgradeAllTokensToOutTokensIfNecessary(
        IERC20 swapOutToken,
        ISuperToken outToken,
        SuperTokenType outTokenType,
        address to
    )
        private
        returns (uint256 outTokenAmount)
    {
        if (outTokenType == SuperTokenType.Wrapper) {
            // Give Super Token maximum allowance if necessary.
            uint256 swapOutTokenBalance = swapOutToken.balanceOf(address(this));
            if (swapOutToken.allowance(address(this), address(outToken)) < swapOutTokenBalance) {
                TransferHelper.safeApprove(address(swapOutToken), address(outToken), type(uint256).max);
            }
            outTokenAmount = _toSuperTokenAmount(swapOutTokenBalance, outToken.getUnderlyingDecimals());
            outToken.upgradeTo(to, outTokenAmount, bytes(""));
            // Reminder that `upgradeTo` expects Super Token decimals.
            // Small dust mount might remain here.
        } else if (outTokenType == SuperTokenType.NativeAsset) {
            if (address(WETH) != address(0)) {
                WETH.withdraw(WETH.balanceOf(address(this)));
            }
            outTokenAmount = address(this).balance;
            ISETH(address(outToken)).upgradeByETHTo{ value: outTokenAmount }(to);
        } else {
            // Pure Super Token
            outTokenAmount = outToken.balanceOf(address(this));
            if (to != address(this)) {
                // Only makes sense to transfer if destination is other than current address.
                TransferHelper.safeTransfer(address(outToken), to, outTokenAmount);
            }
        }
    }

    function _getSuperTokenType(ISuperToken superToken)
        private
        view
        returns (SuperTokenType, address underlyingTokenAddress)
    {
        // TODO: Allow for optimization from off-chain set-up?
        bool isNativeAssetSuperToken = address(superToken) == address(SETH);
        if (isNativeAssetSuperToken) {
            return (SuperTokenType.NativeAsset, address(0));
            // Note that there are a few exceptions where Native Asset Super Tokens have an underlying token,
            // but we don't want to use it for simplification reasons, hence we don't return it.
        } else {
            address underlyingToken = superToken.getUnderlyingToken();
            if (underlyingToken != address(0)) {
                return (SuperTokenType.Wrapper, underlyingToken);
            } else {
                return (SuperTokenType.Pure, address(0));
            }
        }
    }

    function _roundUpOutAmount(
        uint256 outAmount, // 18 decimals
        uint8 underlyingTokenDecimals
    )
        private
        pure
        returns (uint256 outAmountAdjusted)
    {
        if (underlyingTokenDecimals < SUPERTOKEN_DECIMALS) {
            uint256 factor = 10 ** (SUPERTOKEN_DECIMALS - underlyingTokenDecimals);
            outAmountAdjusted = ((outAmount / factor) + 1) * factor; // Effectively rounding up.
        }
        // No need for adjustment when the underlying token has greater or equal decimals.
        else {
            outAmountAdjusted = outAmount;
        }
    }

    function _toSuperTokenAmount(
        uint256 underlyingAmount,
        uint8 underlyingDecimals
    )
        private
        pure
        returns (uint256 superTokenAmount)
    {
        uint256 factor;
        if (underlyingDecimals < SUPERTOKEN_DECIMALS) {
            factor = 10 ** (SUPERTOKEN_DECIMALS - underlyingDecimals);
            superTokenAmount = underlyingAmount * factor;
        } else if (underlyingDecimals > SUPERTOKEN_DECIMALS) {
            factor = 10 ** (underlyingDecimals - SUPERTOKEN_DECIMALS);
            superTokenAmount = underlyingAmount / factor;
        } else {
            superTokenAmount = underlyingAmount;
        }
    }
}