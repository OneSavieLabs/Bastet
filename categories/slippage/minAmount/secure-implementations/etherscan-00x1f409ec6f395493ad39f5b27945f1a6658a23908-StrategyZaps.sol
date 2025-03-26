// SPDX-License-Identifier: MIT
pragma solidity 0.8.9;

import "Ownable.sol";
import "SafeERC20.sol";
import "ERC20.sol";
import "StrategyBase.sol";
import "IGenericVault.sol";
import "IUniV2Router.sol";
import "ICurveTriCrypto.sol";
import "ICVXLocker.sol";

contract stkCvxFxsZaps is Ownable, stkCvxFxsStrategyBase {
    using SafeERC20 for IERC20;

    address public immutable vault;

    address private constant UNION_FXS =
        0xF964b0E3FfdeA659c44a5a52bc0B82A24b89CE0E;
    address private constant CONVEX_LOCKER =
        0x72a19342e8F1838460eBFCCEf09F6585e32db86E;
    address private constant TRICRYPTO =
        0xD51a44d3FaE010294C616388b506AcdA1bfAAE46;
    ICurveTriCrypto triCryptoSwap = ICurveTriCrypto(TRICRYPTO);
    ICVXLocker locker = ICVXLocker(CONVEX_LOCKER);

    constructor(address _vault) {
        vault = _vault;
    }

    /// @notice Change the default swap option for eth -> fxs
    /// @param _newOption - the new option to use
    function setSwapOption(SwapOption _newOption) external onlyOwner {
        SwapOption _oldOption = swapOption;
        swapOption = _newOption;
        emit OptionChanged(_oldOption, swapOption);
    }

    /// @notice Set approvals for the contracts used when swapping & staking
    function setApprovals() external {
        IERC20(CVX_TOKEN).safeApprove(CURVE_CVX_ETH_POOL, 0);
        IERC20(CVX_TOKEN).safeApprove(CURVE_CVX_ETH_POOL, type(uint256).max);

        IERC20(FXS_TOKEN).safeApprove(CURVE_CVXFXS_FXS_POOL, 0);
        IERC20(FXS_TOKEN).safeApprove(CURVE_CVXFXS_FXS_POOL, type(uint256).max);

        IERC20(FXS_TOKEN).safeApprove(CURVE_FXS_ETH_POOL, 0);
        IERC20(FXS_TOKEN).safeApprove(CURVE_FXS_ETH_POOL, type(uint256).max);

        IERC20(FXS_TOKEN).safeApprove(FXS_DEPOSIT, 0);
        IERC20(FXS_TOKEN).safeApprove(FXS_DEPOSIT, type(uint256).max);

        IERC20(FXS_TOKEN).safeApprove(UNISWAP_ROUTER, 0);
        IERC20(FXS_TOKEN).safeApprove(UNISWAP_ROUTER, type(uint256).max);

        IERC20(FRAX_TOKEN).safeApprove(UNISWAP_ROUTER, 0);
        IERC20(FRAX_TOKEN).safeApprove(UNISWAP_ROUTER, type(uint256).max);

        IERC20(FXS_TOKEN).safeApprove(UNIV3_ROUTER, 0);
        IERC20(FXS_TOKEN).safeApprove(UNIV3_ROUTER, type(uint256).max);

        IERC20(FRAX_TOKEN).safeApprove(UNIV3_ROUTER, 0);
        IERC20(FRAX_TOKEN).safeApprove(UNIV3_ROUTER, type(uint256).max);

        IERC20(CVXFXS_TOKEN).safeApprove(CURVE_CVXFXS_FXS_POOL, 0);
        IERC20(CVXFXS_TOKEN).safeApprove(
            CURVE_CVXFXS_FXS_POOL,
            type(uint256).max
        );

        IERC20(CVXFXS_TOKEN).safeApprove(vault, 0);
        IERC20(CVXFXS_TOKEN).safeApprove(vault, type(uint256).max);

        IERC20(USDC_TOKEN).safeApprove(UNIV3_ROUTER, 0);
        IERC20(USDC_TOKEN).safeApprove(UNIV3_ROUTER, type(uint256).max);

        IERC20(CVX_TOKEN).safeApprove(CONVEX_LOCKER, 0);
        IERC20(CVX_TOKEN).safeApprove(CONVEX_LOCKER, type(uint256).max);

        IERC20(FRAX_TOKEN).safeApprove(CURVE_FRAX_USDC_POOL, 0);
        IERC20(FRAX_TOKEN).safeApprove(CURVE_FRAX_USDC_POOL, type(uint256).max);

        IERC20(USDC_TOKEN).safeApprove(CURVE_FRAX_USDC_POOL, 0);
        IERC20(USDC_TOKEN).safeApprove(CURVE_FRAX_USDC_POOL, type(uint256).max);

        IERC20(CRV_TOKEN).safeApprove(CURVE_CRV_ETH_POOL, 0);
        IERC20(CRV_TOKEN).safeApprove(CURVE_CRV_ETH_POOL, type(uint256).max);

        IERC20(CVXFXS_TOKEN).safeApprove(CURVE_CVXFXS_FXS_POOL, 0);
        IERC20(CVXFXS_TOKEN).safeApprove(
            CURVE_CVXFXS_FXS_POOL,
            type(uint256).max
        );
    }

    /// @notice Deposit from FXS
    /// @param amount - the amount of FXS to deposit
    /// @param minAmountOut - min amount of cvxFXS tokens expected
    /// @param to - address to stake on behalf of
    /// @param lock - whether to lock or swap to cvxFXS
    function depositFromFxs(
        uint256 amount,
        uint256 minAmountOut,
        address to,
        bool lock
    ) external notToZeroAddress(to) {
        IERC20(FXS_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        _deposit(amount, minAmountOut, to, lock);
    }

    /// @notice Deposit from legacy uFXS
    /// @param amount - the amount of uFXS to deposit
    /// @param minAmountOut - min amount of cvxFXS tokens expected
    /// @param to - address to stake on behalf of
    function depositFromUFxs(
        uint256 amount,
        uint256 minAmountOut,
        address to
    ) external notToZeroAddress(to) {
        address uFxs = UNION_FXS;
        IERC20(uFxs).safeTransferFrom(msg.sender, address(this), amount);
        IGenericVault(uFxs).withdrawAll(address(this));
        cvxFxsFxsSwap.remove_liquidity_one_coin(
            IERC20(CURVE_CVXFXS_FXS_LP_TOKEN).balanceOf(address(this)),
            1,
            minAmountOut,
            false,
            address(this)
        );
        IGenericVault(vault).depositAll(to);
    }

    function _deposit(
        uint256 amount,
        uint256 minAmountOut,
        address to,
        bool lock
    ) internal {
        if (lock) {
            ICvxFxsDeposit(FXS_DEPOSIT).deposit(amount, true);
        } else {
            cvxFxsFxsSwap.exchange_underlying(0, 1, amount, minAmountOut);
        }
        IGenericVault(vault).depositAll(to);
    }

    /// @notice Deposit into the pounder from ETH
    /// @param minAmountOut - min amount of lp tokens expected
    /// @param to - address to stake on behalf of
    /// @param lock - whether to lock or swap to cvxFXS
    function depositFromEth(
        uint256 minAmountOut,
        address to,
        bool lock
    ) external payable notToZeroAddress(to) {
        require(msg.value > 0, "cheap");
        _depositFromEth(msg.value, minAmountOut, to, lock);
    }

    /// @notice Internal function to deposit ETH to the pounder
    /// @param amount - amount of ETH
    /// @param minAmountOut - min amount of lp tokens expected
    /// @param to - address to stake on behalf of
    /// @param lock - whether to lock or swap to cvxFXS
    function _depositFromEth(
        uint256 amount,
        uint256 minAmountOut,
        address to,
        bool lock
    ) internal {
        uint256 fxsBalance = _swapEthForFxs(amount, swapOption);
        _deposit(fxsBalance, minAmountOut, to, lock);
    }

    /// @notice Deposit into the pounder from any token via Uni interface
    /// @notice Use at your own risk
    /// @dev Zap contract needs approval for spending of inputToken
    /// @param amount - min amount of input token
    /// @param minAmountOut - min amount of cvxCRV expected
    /// @param router - address of the router to use. e.g. 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F for Sushi
    /// @param inputToken - address of the token to swap from, needs to have an ETH pair on router used
    /// @param to - address to stake on behalf of
    /// @param lock - whether to lock or swap to cvxFXS
    function depositViaUniV2EthPair(
        uint256 amount,
        uint256 minAmountOut,
        address router,
        address inputToken,
        address to,
        bool lock
    ) external notToZeroAddress(to) {
        require(router != address(0));

        IERC20(inputToken).safeTransferFrom(msg.sender, address(this), amount);
        address[] memory _path = new address[](2);
        _path[0] = inputToken;
        _path[1] = WETH_TOKEN;

        IERC20(inputToken).safeApprove(router, 0);
        IERC20(inputToken).safeApprove(router, amount);

        IUniV2Router(router).swapExactTokensForETH(
            amount,
            1,
            _path,
            address(this),
            block.timestamp + 1
        );
        _depositFromEth(address(this).balance, minAmountOut, to, lock);
    }

    /// @notice Swap cvxFXS to FXS
    /// @param amount - amount to withdraw
    /// @param minAmountOut - minimum amount of LP tokens expected
    /// @return amount of underlying withdrawn
    function _cvxFxsToFxs(uint256 amount, uint256 minAmountOut)
        internal
        returns (uint256)
    {
        return cvxFxsFxsSwap.exchange_underlying(1, 0, amount, minAmountOut);
    }

    /// @notice Retrieves a user's vault shares and withdraw all
    /// @param amount - amount of shares to retrieve
    /// @return amount of underlying withdrawn
    function _claimAndWithdraw(uint256 amount, uint256 minAmountOut)
        internal
        returns (uint256)
    {
        IERC20(vault).safeTransferFrom(msg.sender, address(this), amount);
        uint256 _cvxFxsAmount = IGenericVault(vault).withdrawAll(address(this));
        return _cvxFxsToFxs(_cvxFxsAmount, minAmountOut);
    }

    /// @notice Claim as FXS
    /// @param amount - amount to withdraw
    /// @param minAmountOut - minimum amount of underlying tokens expected
    /// @param to - address to send withdrawn underlying to
    /// @return amount of underlying withdrawn
    function claimFromVaultAsFxs(
        uint256 amount,
        uint256 minAmountOut,
        address to
    ) public notToZeroAddress(to) returns (uint256) {
        uint256 _fxsAmount = _claimAndWithdraw(amount, minAmountOut);
        IERC20(FXS_TOKEN).safeTransfer(to, _fxsAmount);
        return _fxsAmount;
    }

    /// @notice Claim as native ETH
    /// @param amount - amount to withdraw
    /// @param minAmountOut - minimum amount of ETH expected
    /// @param to - address to send ETH to
    /// @return amount of ETH withdrawn
    function claimFromVaultAsEth(
        uint256 amount,
        uint256 minAmountOut,
        address to
    ) public notToZeroAddress(to) returns (uint256) {
        uint256 _ethAmount = _claimAsEth(amount);
        require(_ethAmount >= minAmountOut, "Slippage");
        (bool success, ) = to.call{value: _ethAmount}("");
        require(success, "ETH transfer failed");
        return _ethAmount;
    }

    /// @notice Withdraw as native ETH (internal)
    /// @param amount - amount to withdraw
    /// @return amount of ETH withdrawn
    function _claimAsEth(uint256 amount) public returns (uint256) {
        uint256 _fxsAmount = _claimAndWithdraw(amount, 0);
        return _swapFxsForEth(_fxsAmount, swapOption);
    }

    /// @notice Claim to any token via a univ2 router
    /// @notice Use at your own risk
    /// @param amount - amount of uFXS to unstake
    /// @param minAmountOut - min amount of output token expected
    /// @param router - address of the router to use. e.g. 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F for Sushi
    /// @param outputToken - address of the token to swap to
    /// @param to - address of the final recipient of the swapped tokens
    function claimFromVaultViaUniV2EthPair(
        uint256 amount,
        uint256 minAmountOut,
        address router,
        address outputToken,
        address to
    ) public notToZeroAddress(to) {
        require(router != address(0));
        _claimAsEth(amount);
        address[] memory _path = new address[](2);
        _path[0] = WETH_TOKEN;
        _path[1] = outputToken;
        IUniV2Router(router).swapExactETHForTokens{
            value: address(this).balance
        }(minAmountOut, _path, to, block.timestamp + 1);
    }

    /// @notice Claim as USDT via Tricrypto
    /// @param amount - the amount of uFXS to unstake
    /// @param minAmountOut - the min expected amount of USDT to receive
    /// @param to - the adress that will receive the USDT
    /// @return amount of USDT obtained
    function claimFromVaultAsUsdt(
        uint256 amount,
        uint256 minAmountOut,
        address to
    ) public notToZeroAddress(to) returns (uint256) {
        uint256 _ethAmount = _claimAsEth(amount);
        _swapEthToUsdt(_ethAmount, minAmountOut);
        uint256 _usdtAmount = IERC20(USDT_TOKEN).balanceOf(address(this));
        IERC20(USDT_TOKEN).safeTransfer(to, _usdtAmount);
        return _usdtAmount;
    }

    /// @notice swap ETH to USDT via Curve's tricrypto
    /// @param amount - the amount of ETH to swap
    /// @param minAmountOut - the minimum amount expected
    function _swapEthToUsdt(uint256 amount, uint256 minAmountOut) internal {
        triCryptoSwap.exchange{value: amount}(
            2, // ETH
            0, // USDT
            amount,
            minAmountOut,
            true
        );
    }

    /// @notice Claim as CVX via CurveCVX
    /// @param amount - the amount of uFXS to unstake
    /// @param minAmountOut - the min expected amount of USDT to receive
    /// @param to - the adress that will receive the CVX
    /// @param lock - whether to lock the CVX or not
    /// @return amount of CVX obtained
    function claimFromVaultAsCvx(
        uint256 amount,
        uint256 minAmountOut,
        address to,
        bool lock
    ) public notToZeroAddress(to) returns (uint256) {
        uint256 _ethAmount = _claimAsEth(amount);
        uint256 _cvxAmount = _swapEthToCvx(_ethAmount, minAmountOut);
        if (lock) {
            locker.lock(to, _cvxAmount, 0);
        } else {
            IERC20(CVX_TOKEN).safeTransfer(to, _cvxAmount);
        }
        return _cvxAmount;
    }

    modifier notToZeroAddress(address _to) {
        require(_to != address(0), "Invalid address!");
        _;
    }
}