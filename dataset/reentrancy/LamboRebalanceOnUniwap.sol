// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {VirtualToken} from "../VirtualToken.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {IQuoter} from "../interfaces/Uniswap/IQuoter.sol";
import {IDexRouter} from "../interfaces/OKX/IDexRouter.sol";
import {IMorpho} from "@morpho/interfaces/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "@morpho/interfaces/IMorphoCallbacks.sol";

contract LamboRebalanceOnUniwap is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    IMorphoFlashLoanCallback
{
    using SafeERC20 for IERC20;

    uint256 private constant _BUY_MASK = 1 << 255; // Mask for identifying if the swap is one-for-zero
    uint256 private constant _SELL_MASK = 0; // Mask for identifying if the swap is one-for-zero

    address public constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant morphoVault = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address public constant quoter = 0x5e55C9e631FAE526cd4B0526C4818D6e0a9eF0e3;
    address public constant OKXRouter = 0x7D0CcAa3Fac1e5A943c5168b6CEd828691b46B36;
    address public constant OKXTokenApprove = 0x40aA958dd87FC8305b97f2BA922CDdCa374bcD7f;

    address public veth;
    address public uniswapPool;
    uint24 public fee;

    function initialize(address _multiSign, address _vETH, address _uniswap, uint24 _fee) public initializer {
        require(_multiSign != address(0), "Invalid _multiSign address");
        require(_vETH != address(0), "Invalid _vETH address");
        require(_uniswap != address(0), "Invalid _uniswap address");

        __Ownable_init(_multiSign);
        __ReentrancyGuard_init();

        fee = _fee;
        veth = _vETH;
        uniswapPool = _uniswap;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function extractProfit(address to, address token) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(to, balance);
        }
    }

    function rebalance(uint256 directionMask, uint256 amountIn, uint256 amountOut) external nonReentrant {
        uint256 balanceBefore = IERC20(weth).balanceOf(address(this));
        bytes memory data = abi.encode(directionMask, amountIn, amountOut);
        IMorpho(morphoVault).flashLoan(weth, amountIn, data);
        uint256 balanceAfter = IERC20(weth).balanceOf(address(this));
        uint256 profit = balanceAfter - balanceBefore;
        require(profit > 0, "No profit made");
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        require(msg.sender == address(morphoVault), "Caller is not morphoVault");
        (uint256 directionMask, uint256 amountIn, uint256 amountOut) = abi.decode(data, (uint256, uint256, uint256));
        require(amountIn == assets, "Amount in does not match assets");

        uint256 _v3pool = uint256(uint160(uniswapPool)) | (directionMask);
        uint256[] memory pools = new uint256[](1);
        pools[0] = _v3pool;

        if (directionMask == _BUY_MASK) {
            _executeBuy(amountIn, pools);
        } else {
            _executeSell(amountIn, pools);
        }

        require(IERC20(weth).approve(address(morphoVault), assets), "Approve failed");
    }

    function _executeBuy(uint256 amountIn, uint256[] memory pools) internal {
        uint256 initialBalance = address(this).balance;

        // Execute buy
        require(IERC20(weth).approve(address(OKXTokenApprove), amountIn), "Approve failed");
        uint256 uniswapV3AmountOut = IDexRouter(OKXRouter).uniswapV3SwapTo(
            uint256(uint160(address(this))),
            amountIn,
            0,
            pools
        );
        VirtualToken(veth).cashOut(uniswapV3AmountOut);

        // SlowMist [N11]
        uint256 newBalance = address(this).balance - initialBalance;
        if (newBalance > 0) {
            IWETH(weth).deposit{value: newBalance}();
        }
    }

    function _executeSell(uint256 amountIn, uint256[] memory pools) internal {
        IWETH(weth).withdraw(amountIn);
        VirtualToken(veth).cashIn{value: amountIn}(amountIn);
        require(IERC20(veth).approve(address(OKXTokenApprove), amountIn), "Approve failed");
        IDexRouter(OKXRouter).uniswapV3SwapTo(uint256(uint160(address(this))), amountIn, 0, pools);
    }

    function previewRebalance()
        public
        view
        returns (bool result, uint256 directionMask, uint256 amountIn, uint256 amountOut)
    {
        address tokenIn;
        address tokenOut;
        (tokenIn, tokenOut, amountIn) = _getTokenInOut();
        (amountOut, directionMask) = _getQuoteAndDirection(tokenIn, tokenOut, amountIn);
        result = amountOut > amountIn;
    }

    function _getTokenBalances() internal view returns (uint256 wethBalance, uint256 vethBalance) {
        wethBalance = IERC20(weth).balanceOf(uniswapPool);
        vethBalance = IERC20(veth).balanceOf(uniswapPool);
    }

    function _getTokenInOut() internal view returns (address tokenIn, address tokenOut, uint256 amountIn) {
        (uint256 wethBalance, uint256 vethBalance) = _getTokenBalances();
        uint256 targetBalance = (wethBalance + vethBalance) / 2;

        if (vethBalance > targetBalance) {
            amountIn = vethBalance - targetBalance;
            tokenIn = weth;
            tokenOut = veth;
        } else {
            amountIn = wethBalance - targetBalance;
            tokenIn = veth;
            tokenOut = weth;
        }

        require(amountIn > 0, "amountIn must be greater than zero");
    }

    function _getQuoteAndDirection(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (uint256 amountOut, uint256 directionMask) {
        (amountOut, , , ) = IQuoter(quoter).quoteExactInputSingleWithPool(
            IQuoter.QuoteExactInputSingleWithPoolParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                amountIn: amountIn,
                fee: fee,
                pool: uniswapPool,
                sqrtPriceLimitX96: 0
            })
        );
        directionMask = (tokenIn == weth) ? _BUY_MASK : _SELL_MASK;
    }

    receive() external payable {}
}
