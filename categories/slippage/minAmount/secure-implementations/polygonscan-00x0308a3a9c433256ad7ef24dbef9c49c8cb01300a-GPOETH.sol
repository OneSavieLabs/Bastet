// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import "./BaseGPO.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

/**
____________________________
Description:
GoldPesa Option Contract (GPO) - 1 GPO represents the option to purchase 1 GPX at spot gold price + 1 %.
__________________________________
 */
contract GPOEth is BaseGPO {

    /// @notice Uniswap Router Address
    ISwapRouter public immutable swapRouter;

    /**
     * @dev Initializes the contract and sets the Uniswap SwapRouter.
     */
    constructor(ISwapRouter _swapRouter) BaseGPO() {
        swapRouter = _swapRouter;
    }

    /**
     * @dev Additional requirements before transferring tokens.
     */
    function _beforeTokenTransferAdditional(address from, address to, uint256 amount) internal virtual override {
        // Ensures that GPO token holders cannot execute a swap directly with the GPO/USDC liquidity pool on Uniswap V3. 
        // All swaps must be executed on the GoldPesa DEX unless "freeTrade" has be enabled.
        if (authorizedPool != address(0x0) && (from == authorizedPool || to == authorizedPool)) 
            require(freeTrade || (whitelistedWallets[to] && whitelistedWallets[from]), "GPO_ERR: UniswapV3 functionality is only allowed through GPO's protocol"); 
    }
    
    /**
     * @notice Swap GPO for an exact amount of USDC.
     * 
     * @param amountInMaximum: Maxmimum amount of GPO available for swap 
     * @param amountOut: Exact amount of USDC needed
     * @param deadline: deadline in unix time for the transaction
     *
     * @return amountIn : Exact amount of GPO used for swap 
     *
     * NOTE: Any extra GPO tokens not used in the Swap are returned back to the user.
     */
    function swapToExactOutput(uint256 amountInMaximum, uint256 amountOut, uint256 deadline) external returns (uint256 amountIn) {
        require(amountInMaximum > 0 && amountOut > 0);
        require(swapEnabled || whitelistedWallets[_msgSender()]);
        
        _transfer(_msgSender(), address(this), amountInMaximum);
        _approve(address(this), address(swapRouter), amountInMaximum);

        if (deadline == 0)
            deadline = block.timestamp + 30*60;
        
        ISwapRouter.ExactOutputSingleParams memory params =
            ISwapRouter.ExactOutputSingleParams({
                tokenIn: address(this),
                tokenOut: addrUSDC,
                fee: BaseGPO.swapPoolFee,
                recipient: address(this),
                deadline: deadline,
                amountOut: amountOut,
                amountInMaximum: amountInMaximum,
                sqrtPriceLimitX96: 0
            });
        amountIn = swapRouter.exactOutputSingle(params);
        uint256 fee = calculateFeeOnSwap(amountOut);
        uint256 amountSwap = amountOut - fee;
        
        TransferHelper.safeTransfer(addrUSDC, _msgSender(), amountSwap);
        distributeFee(fee); 

        if (amountIn < amountInMaximum) {
            _transfer(address(this), _msgSender(), amountInMaximum - amountIn);
        } 
        emit TokensSwaped(_msgSender(), amountIn, amountOut, false);
    }

    /**
     * @notice Swap exact amount of GPO for USDC.
     * 
     * @param amountIn: Exact amount of GPO for swap 
     * @param amountOutMinimum: Minimum acceptable USDC amount received
     * @param deadline: deadline in unix time for the transaction
     *
     * @return amountOut : Exact amount of USDC received 
     */
    function swapToExactInput(uint256 amountIn, uint256 amountOutMinimum, uint256 deadline) external returns (uint256 amountOut) {
        require(amountIn > 0);
        require(swapEnabled || whitelistedWallets[_msgSender()]);

        _transfer(_msgSender(), address(this), amountIn);
        _approve(address(this), address(swapRouter), amountIn);

        if (deadline == 0)
            deadline = block.timestamp + 30*60;

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: address(this),
                tokenOut: addrUSDC,
                fee: BaseGPO.swapPoolFee,
                recipient: address(this),
                deadline: deadline,
                amountIn: amountIn,
                amountOutMinimum: amountOutMinimum,
                sqrtPriceLimitX96: 0
            });

        amountOut = swapRouter.exactInputSingle(params);

        uint256 fee = calculateFeeOnSwap(amountOut);
        uint256 amountSwap = amountOut - fee;

        TransferHelper.safeTransfer(addrUSDC, _msgSender(), amountSwap);
        distributeFee(fee);

        emit TokensSwaped(_msgSender(), amountIn, amountOut, false);

        return amountSwap;
    }

    /**
     * @notice Swap USDC for an exact amount of GPO.
     * 
     * @param amountInMaximum: Maxmimum amount of USDC/USD available for swap 
     * @param amountOut: Exact amount of GPO needed
     * @param deadline: deadline in unix time for the transaction
     *
     * @return amountIn : Exact amount of USDC used for swap 
     *
     * NOTE: Any extra USDC tokens not used in the Swap are returned back to the user.
     */
    function swapFromExactOutput(uint256 amountInMaximum, uint256 amountOut, uint256 deadline) external returns (uint256 amountIn) {
        require(swapEnabled || whitelistedWallets[_msgSender()]);
        require(amountInMaximum > 0 && amountOut > 0);

        TransferHelper.safeTransferFrom(addrUSDC, _msgSender(), address(this), amountInMaximum);
        uint256 fee = calculateFeeOnSwap(amountInMaximum);
        uint256 amountSwap = amountInMaximum - fee;
        distributeFee(fee);

        
        if (deadline == 0)
            deadline = block.timestamp + 30*60;
        
        TransferHelper.safeApprove(addrUSDC, address(swapRouter), amountSwap);
        ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter.ExactOutputSingleParams({
                tokenIn: addrUSDC,
                tokenOut: address(this),
                fee: BaseGPO.swapPoolFee,
                recipient: address(this),
                deadline: deadline,
                amountOut: amountOut,
                amountInMaximum: amountSwap,
                sqrtPriceLimitX96: 0
        });
        amountIn = swapRouter.exactOutputSingle(params);
        
        _transfer(address(this), _msgSender(), amountOut);

        if (amountIn < amountSwap) {
            TransferHelper.safeTransfer(addrUSDC, _msgSender(), amountSwap - amountIn);
        } 

        emit TokensSwaped(_msgSender(), amountIn, amountOut, true);
    }
    
    /**
     * @notice Swap exact amount of USDC for GPO.
     * 
     * @param amountIn: Exact amount of USDC for swap 
     * @param amountOutMinimum: Minimum accceptable GPO amount received
     * @param deadline: deadline in unix time for the transaction
     *
     * @return amountOut : Exact amount of GPO received 
     */
    function swapFromExactInput(uint256 amountIn, uint256 amountOutMinimum, uint256 deadline) external returns (uint256 amountOut) {
        require(amountIn > 0 && amountOutMinimum > 0);
        require(swapEnabled || whitelistedWallets[_msgSender()]);

        uint256 fee = calculateFeeOnSwap(amountIn);
        TransferHelper.safeTransferFrom(addrUSDC, _msgSender(), address(this), amountIn);
        uint256 amountSwap = amountIn - fee;
        distributeFee(fee);
        TransferHelper.safeApprove(addrUSDC, address(swapRouter), amountSwap);

        if (deadline == 0)
            deadline = block.timestamp + 30*60;

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: addrUSDC,
                tokenOut: address(this),
                fee: BaseGPO.swapPoolFee,
                recipient: address(this),
                deadline: deadline,
                amountIn: amountSwap,
                amountOutMinimum: amountOutMinimum,
                sqrtPriceLimitX96: 0
            });
        amountOut = swapRouter.exactInputSingle(params);
        _transfer(address(this), _msgSender(), amountOut);

        emit TokensSwaped(_msgSender(), amountIn, amountOut, true);
    }

    /**
     * @dev GPO Owner sets the USDC contract address, the Uniswap pool fee and accordingly includes the derived Uniswap liquidity pool address to the whitelistedWallets mapping.
     * 
     * @param USDC USDC contract address
     * @param poolFee Uniswap V3 pool fee * 10000
     */
    function setPoolParameters(address USDC, uint24 poolFee) external onlyOwner {
        require(USDC != address(0x0));

        addrUSDC = USDC;
        BaseGPO.swapPoolFee = poolFee;
        whitelistedWallets[authorizedPool] = false;

        // taken from @uniswap/v3-periphery/contracts/libraries/PoolAddress.sol
        address token0 = address(this);
        address token1 = USDC;
        if (token0 > token1) (token0, token1) = (token1, token0);

        authorizedPool = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex'ff',
                            0x1F98431c8aD98523631AE4a59f267346ea31F984,
                            keccak256(abi.encode(token0, token1, poolFee)),
                            bytes32(0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54)
                        )
                    )
                )
            )
        );
        whitelistedWallets[authorizedPool] = true;
        emit PoolParametersChanged(USDC, poolFee);
    }
}