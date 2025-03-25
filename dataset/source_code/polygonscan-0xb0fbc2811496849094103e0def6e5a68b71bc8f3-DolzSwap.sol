// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract DolzSwap is Ownable {
    IUniswapV2Router02 public uniswapV2Router;
    ISwapRouter public uniswapV3Router;

    address public nativeToken;

    event v3multihopSwap(address userAddress, uint256 swapAmount);
    event v3swap(address userAddress, uint256 swapAmount);
    event v2swap(address userAddress, uint256 swapAmount);

    constructor(address _uniswapV2Router, address _uniswapV3Router) {
        uniswapV2Router = IUniswapV2Router02(_uniswapV2Router);
        uniswapV3Router = ISwapRouter(_uniswapV3Router);

        if (block.chainid == 137) {
            nativeToken = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270; // WMATIC
        } else {
            revert("Unsupported chain");
        }
    }

    function setUniswapV2Router(address _uniswapV2Router) public onlyOwner {
        uniswapV2Router = IUniswapV2Router02(_uniswapV2Router);
    }

    function setUniswapV3Router(address _uniswapV3Router) public onlyOwner {
        uniswapV3Router = ISwapRouter(_uniswapV3Router);
    }

    function setNativetoken(address _nativeToken) public onlyOwner {
        nativeToken = _nativeToken;
    }

    function swapOnUniswapV2(
        address _tokenToReceive,
        uint24 _additionnalDeadline,
        address _receiver
    ) external payable {
        require(msg.value > 0, "send more than 0");

        address[] memory path = new address[](2);
        path[0] = nativeToken;
        path[1] = _tokenToReceive;
        uniswapV2Router.swapExactETHForTokens{value: msg.value}(
            0,
            path,
            _receiver,
            block.timestamp + _additionnalDeadline
        );
        emit v2swap(_receiver, msg.value);
    }

    function swapOnUniswapV3(
        address _tokenToReceive,
        uint24 _fee,
        uint24 _additionnalDeadline,
        address _receiver
    ) external payable {
        require(msg.value > 0, "send more than 0");
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: nativeToken,
                tokenOut: _tokenToReceive,
                fee: _fee,
                recipient: _receiver,
                deadline: block.timestamp + _additionnalDeadline,
                amountIn: msg.value,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });

        uniswapV3Router.exactInputSingle{value: msg.value}(params);
        emit v3swap(_receiver, msg.value);
    }

    function swapExactInputMultihop(
        uint24 _firstFee,
        address _multihopToken,
        uint24 _secondFee,
        address _tokenToReceive,
        uint24 _additionnalDeadline,
        address _receiver
    ) external payable {
        require(msg.value > 0, "send more than 0");

        ISwapRouter.ExactInputParams memory params = ISwapRouter
            .ExactInputParams({
                path: abi.encodePacked(
                    nativeToken,
                    _firstFee,
                    _multihopToken,
                    _secondFee,
                    _tokenToReceive
                ),
                recipient: _receiver,
                deadline: block.timestamp + _additionnalDeadline,
                amountIn: msg.value,
                amountOutMinimum: 0
            });

        uniswapV3Router.exactInput{value: msg.value}(params);
        emit v3multihopSwap(_receiver, msg.value);
    }

    receive() external payable {}
}