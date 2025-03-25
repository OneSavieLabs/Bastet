// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;
pragma experimental ABIEncoderV2;

import {ServiceRegistry, UNISWAP_ROUTER_CONTRACT} from "../ServiceRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapHandler} from "../../interfaces/core/ISwapHandler.sol";
import {IV3SwapRouter} from "../../interfaces/uniswap/v3/ISwapRouter.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title UseSwapper
 *
 * @dev Abstract contract to integrate the use of Uniswap V3
 *      Provides functions to initialize, access and swap
 *      It allows any contract to swap an ERC-20 for another ERC-20 with a fixed
 *      input amoun  or a fixed output amount of tokens.
 *
 *      During the contract initialization it sets the uniswap router address from the
 *      service registry
 *
 * @author Chef Kenji <chef.kenji@bakerfi.xyz>
 * @author Chef Kal-El <chef.kal-el@bakerfi.xyz>
 */
abstract contract UseSwapper is ISwapHandler, Initializable {
    using SafeERC20 for IERC20;

    error InvalidUniRouterContract();
    error InvalidInputToken();
    error InvalidOutputToken();
    error InvalidFeeTier();

    event Swap(
        address indexed assetIn,
        address assetOut,
        uint256 assetInAmount,
        uint256 assetOutAmount
    );
    error SwapFailed();

    IV3SwapRouter private _uniRouter;

    function _initUseSwapper(ServiceRegistry registry) internal onlyInitializing {
        _uniRouter = IV3SwapRouter(registry.getServiceFromHash(UNISWAP_ROUTER_CONTRACT));
        if (address(_uniRouter) == address(0)) revert InvalidUniRouterContract();
    }

    function uniRouter() public view returns (IV3SwapRouter) {
        return _uniRouter;
    }

    function uniRouterA() public view returns (address) {
        return address(_uniRouter);
    }

    function _swap(
        ISwapHandler.SwapParams memory params
    ) internal override returns (uint256 amountOut) {
        if (params.underlyingIn == address(0)) revert InvalidInputToken();
        if (params.underlyingOut == address(0)) revert InvalidOutputToken();
        uint24 fee = params.feeTier;
        if (fee == 0) revert InvalidFeeTier();

        // Exact Input
        if (params.mode == ISwapHandler.SwapType.EXACT_INPUT) {
            amountOut = _uniRouter.exactInputSingle(
                IV3SwapRouter.ExactInputSingleParams({
                    tokenIn: params.underlyingIn,
                    tokenOut: params.underlyingOut,
                    amountIn: params.amountIn,
                    amountOutMinimum: 0,
                    fee: fee,
                    recipient: address(this),
                    sqrtPriceLimitX96: 0
                })
            );
            if (amountOut == 0) {
                revert SwapFailed();
            }
            emit Swap(params.underlyingIn, params.underlyingOut, params.amountIn, amountOut);
            // Exact Output
        } else if (params.mode == ISwapHandler.SwapType.EXACT_OUTPUT) {
            uint256 amountIn = _uniRouter.exactOutputSingle(
                IV3SwapRouter.ExactOutputSingleParams({
                    tokenIn: params.underlyingIn,
                    tokenOut: params.underlyingOut,
                    fee: fee,
                    recipient: address(this),
                    amountOut: params.amountOut,
                    amountInMaximum: params.amountIn,
                    sqrtPriceLimitX96: 0
                })
            );
            if (amountIn < params.amountIn) {
                IERC20(params.underlyingIn).safeTransfer(address(this), params.amountIn - amountIn);
            }
            emit Swap(params.underlyingIn, params.underlyingOut, amountIn, params.amountOut);
            amountOut = params.amountOut;
        }
    }
}