// SPDX-License-Identifier: MIT

pragma solidity >=0.7.0 <0.9.0;

import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

contract ExchangeCurrency {
    address public admin;
    address public RTUSD;
    ISwapRouter public immutable swapRouter;

    // For this example, we will set the pool fee to 0.3%.
    uint24 public poolFee = 3000;

    // SwapRouter = 0xE592427A0AEce92De3Edee1F18E0157C05861564
    // constant RTUSD = 0x4CDad76C01a87b24f54D9A507DEBC18FAf474073;
    // const MMSGDAddress = "0x106673b64A2c0adD1Be09d6A839a0eb43b522173";
    // const MMKAddress = "0x391C472669bBcEB68B43fa571540e6be25D55E28";

    constructor(ISwapRouter swapRouter_, address rtUSD_) {
        admin = msg.sender;
        swapRouter = swapRouter_;
        RTUSD = rtUSD_;
    }

    // ============ MODIFIER ============
    modifier onlyAdmin() {
        require(admin == msg.sender, "Ownable: caller is not the admin");
        _;
    }

    // ============ OWNER ============
    function setAdmin(address admin_) public onlyAdmin {
        require(admin_ != address(0), "SetAdmin: Zero address owner");
        admin = admin_;
    }

    function setRTUSD(address rtUSD_) public onlyAdmin {
        require(rtUSD_ != address(0), "setRTUSD: Zero address rtUSD");
        RTUSD = rtUSD_;
    }

    function setPoolFee(uint24 poolFee_) public onlyAdmin {
        poolFee = poolFee_;
    }

    // ============ EVENTS ============
    event SwapExactInput(
        address fromToken,
        address toToken,
        uint amountIn,
        uint amountOut
    );
    event SwapExactOutput(
        address fromToken,
        address toToken,
        uint amountIn,
        uint amountOut
    );

    function swapExactInputSingleHop(
        address fromToken,
        address toToken,
        uint amountIn
    ) external returns (uint amountOut) {
        TransferHelper.safeTransferFrom(
            (fromToken),
            msg.sender,
            address(this),
            amountIn
        );
        TransferHelper.safeApprove((fromToken), address(swapRouter), amountIn);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: fromToken,
                tokenOut: toToken,
                fee: poolFee,
                recipient: msg.sender,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });

        amountOut = swapRouter.exactInputSingle(params);
        emit SwapExactInput(fromToken, toToken, amountIn, amountOut);
    }

    function swapExactInputMultihop(
        address fromToken,
        address toToken,
        uint amountIn
    ) external returns (uint amountOut) {
        TransferHelper.safeTransferFrom(
            (fromToken),
            msg.sender,
            address(this),
            amountIn
        );
        TransferHelper.safeApprove((fromToken), address(swapRouter), amountIn);

        ISwapRouter.ExactInputParams memory params = ISwapRouter
            .ExactInputParams({
                path: abi.encodePacked(
                    fromToken,
                    poolFee,
                    RTUSD,
                    poolFee,
                    toToken
                ),
                recipient: msg.sender,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0
            });

        amountOut = swapRouter.exactInput(params);
        emit SwapExactInput(fromToken, toToken, amountIn, amountOut);
    }

    function swapExactOutputMultihop(
        address fromToken,
        address toToken,
        uint amountOut,
        uint amountInMaximum
    ) external returns (uint amountIn) {
        TransferHelper.safeTransferFrom(
            (fromToken),
            msg.sender,
            address(this),
            amountInMaximum
        );
        TransferHelper.safeApprove(
            (fromToken),
            address(swapRouter),
            amountInMaximum
        );

        ISwapRouter.ExactOutputParams memory params = ISwapRouter
            .ExactOutputParams({
                path: abi.encodePacked(
                    toToken,
                    poolFee,
                    RTUSD,
                    poolFee,
                    fromToken
                ),
                recipient: msg.sender,
                deadline: block.timestamp,
                amountOut: amountOut,
                amountInMaximum: amountInMaximum
            });
        amountIn = swapRouter.exactOutput(params);

        if (amountIn < amountInMaximum) {
            TransferHelper.safeApprove(fromToken, address(swapRouter), 0);
            TransferHelper.safeTransferFrom(
                fromToken,
                address(this),
                msg.sender,
                amountInMaximum - amountIn
            );
        }

        emit SwapExactOutput(fromToken, toToken, amountIn, amountOut);
    }
}