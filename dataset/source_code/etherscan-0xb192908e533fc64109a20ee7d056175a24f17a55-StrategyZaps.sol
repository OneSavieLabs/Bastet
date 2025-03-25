// SPDX-License-Identifier: MIT
pragma solidity 0.8.9;

import "SafeERC20.sol";
import "ReentrancyGuard.sol";
import "ERC20.sol";
import "UnionBase.sol";
import "IGenericVault.sol";
import "IUniV2Router.sol";
import "ICurveTriCrypto.sol";
import "IERC4626.sol";
import "IPirexCVX.sol";
import "ILpxCvx.sol";

contract PCvxZaps is UnionBase, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address private constant PIREX_CVX =
        0x35A398425d9f1029021A92bc3d2557D42C8588D7;
    address private constant PXCVX_TOKEN =
        0xBCe0Cf87F513102F22232436CCa2ca49e815C3aC;
    address private constant PXCVX_VAULT =
        0x8659Fc767cad6005de79AF65dAfE4249C57927AF;
    address private constant WETH_TOKEN =
        0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant TRICRYPTO =
        0xD51a44d3FaE010294C616388b506AcdA1bfAAE46;
    address private constant USDT_TOKEN =
        0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address private constant LPX_CVX =
        0x389fB29230D02e67eB963C1F5A00f2b16f95BEb7;
    IERC4626 vault = IERC4626(PXCVX_VAULT);
    ICurveTriCrypto triCryptoSwap = ICurveTriCrypto(TRICRYPTO);

    /// @notice Set approvals for the contracts used when swapping & staking
    function setApprovals() external {
        IERC20(PXCVX_TOKEN).safeApprove(PXCVX_VAULT, 0);
        IERC20(PXCVX_TOKEN).safeApprove(PXCVX_VAULT, type(uint256).max);

        IERC20(CVX_TOKEN).safeApprove(PIREX_CVX, 0);
        IERC20(CVX_TOKEN).safeApprove(PIREX_CVX, type(uint256).max);

        IERC20(CVX_TOKEN).safeApprove(CURVE_CVX_ETH_POOL, 0);
        IERC20(CVX_TOKEN).safeApprove(CURVE_CVX_ETH_POOL, type(uint256).max);

        IERC20(CVX_TOKEN).safeApprove(LPX_CVX, 0);
        IERC20(CVX_TOKEN).safeApprove(LPX_CVX, type(uint256).max);

        IERC20(PXCVX_TOKEN).safeApprove(LPX_CVX, 0);
        IERC20(PXCVX_TOKEN).safeApprove(LPX_CVX, type(uint256).max);

        IERC20(CVXCRV_TOKEN).safeApprove(CURVE_CVXCRV_CRV_POOL, 0);
        IERC20(CVXCRV_TOKEN).safeApprove(
            CURVE_CVXCRV_CRV_POOL,
            type(uint256).max
        );

        IERC20(CRV_TOKEN).safeApprove(CURVE_CRV_ETH_POOL, 0);
        IERC20(CRV_TOKEN).safeApprove(CURVE_CRV_ETH_POOL, type(uint256).max);

        IERC20(CRV_TOKEN).safeApprove(CURVE_CVXCRV_CRV_POOL, 0);
        IERC20(CRV_TOKEN).safeApprove(CURVE_CVXCRV_CRV_POOL, type(uint256).max);
    }

    function _deposit(
        uint256 _amount,
        uint256 _minAmountOut,
        address _to,
        bool _lock
    ) internal {
        if (!_lock) {
            ILpxCvx(LPX_CVX).swap(
                ILpxCvx.Token.CVX,
                _amount,
                _minAmountOut,
                0,
                1
            );
            uint256 _pxCvxAmount = IERC20(PXCVX_TOKEN).balanceOf(address(this));
            vault.deposit(_pxCvxAmount, _to);
        } else {
            require(_amount >= _minAmountOut, "slippage");
            IPirexCVX(PIREX_CVX).deposit(_amount, _to, true, address(0));
        }
    }

    /// @notice Deposit into the pounder from ETH
    /// @param minAmountOut - min amount of pCVX tokens expected
    /// @param to - address to stake on behalf of
    /// @param lock - whether to lock or swap cvx to pxcvx
    function depositFromEth(
        uint256 minAmountOut,
        address to,
        bool lock
    ) external payable notToZeroAddress(to) {
        require(msg.value > 0, "cheap");
        _depositFromEth(msg.value, minAmountOut, to, lock);
    }

    /// @notice Deposit into the pounder from CRV
    /// @param minAmountOut - min amount of pCVX tokens expected
    /// @param to - address to stake on behalf of
    /// @param lock - whether to lock or swap cvx to pxcvx
    function depositFromCrv(
        uint256 amount,
        uint256 minAmountOut,
        address to,
        bool lock
    ) external notToZeroAddress(to) {
        IERC20(CRV_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        uint256 _ethBalance = _swapCrvToEth(amount);
        _depositFromEth(_ethBalance, minAmountOut, to, lock);
    }

    /// @notice Deposit into the pounder from CVX
    /// @param minAmountOut - min amount of pCVX tokens expected
    /// @param to - address to stake on behalf of
    /// @param lock - whether to lock or swap cvx to pxcvx
    function depositFromCvx(
        uint256 amount,
        uint256 minAmountOut,
        address to,
        bool lock
    ) external notToZeroAddress(to) {
        IERC20(CVX_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        _deposit(amount, minAmountOut, to, lock);
    }

    /// @notice Deposit into the pounder from cvxCRV
    /// @param minAmountOut - min amount of pCVX tokens expected
    /// @param to - address to stake on behalf of
    /// @param lock - whether to lock or swap cvx to pxcvx
    function depositFromCvxCrv(
        uint256 amount,
        uint256 minAmountOut,
        address to,
        bool lock
    ) external notToZeroAddress(to) {
        IERC20(CVXCRV_TOKEN).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );
        uint256 _crvBalance = _swapCvxCrvToCrv(amount, address(this));
        uint256 _ethBalance = _swapCrvToEth(_crvBalance);
        _depositFromEth(_ethBalance, minAmountOut, to, lock);
    }

    /// @notice Internal function to deposit ETH to the pounder
    /// @param _amount - amount of ETH
    /// @param _minAmountOut - min amount of tokens expected
    /// @param _to - address to stake on behalf of
    /// @param _lock - whether to lock or swap cvx to pxcvx
    function _depositFromEth(
        uint256 _amount,
        uint256 _minAmountOut,
        address _to,
        bool _lock
    ) internal {
        uint256 _cvxBalance = _swapEthToCvx(_amount);
        _deposit(_cvxBalance, _minAmountOut, _to, _lock);
    }

    /// @notice Deposit into the pounder from any token via Uni interface
    /// @notice Use at your own risk
    /// @dev Zap contract needs approval for spending of inputToken
    /// @param amount - min amount of input token
    /// @param minAmountOut - min amount of cvxCRV expected
    /// @param router - address of the router to use. e.g. 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F for Sushi
    /// @param inputToken - address of the token to swap from, needs to have an ETH pair on router used
    /// @param to - address to stake on behalf of
    /// @param lock - whether to lock or swap cvx to pxcvx
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

    /// @notice Unstake and converts pxCVX to CVX
    /// @param _amount - amount to withdraw
    /// @param _minAmountOut - minimum amount of LP tokens expected
    /// @param _to - receiver
    /// @return amount of underlying withdrawn
    function _claimAsCvx(
        uint256 _amount,
        uint256 _minAmountOut,
        address _to
    ) internal returns (uint256) {
        ILpxCvx(LPX_CVX).swap(
            ILpxCvx.Token.pxCVX,
            _amount,
            _minAmountOut,
            1,
            0
        );
        uint256 _cvxBalance = IERC20(CVX_TOKEN).balanceOf(address(this));
        IERC20(CVX_TOKEN).safeTransfer(_to, _cvxBalance);
        return _cvxBalance;
    }

    /// @notice Retrieves a user's vault shares and withdraw all
    /// @param _amount - amount of shares to retrieve
    function _claimAndWithdraw(uint256 _amount) internal {
        require(
            vault.transferFrom(msg.sender, address(this), _amount),
            "error"
        );
        vault.redeem(_amount, address(this), address(this));
    }

    /// @notice Claim as CVX
    /// @param amount - amount to withdraw
    /// @param minAmountOut - minimum amount of underlying tokens expected
    /// @param to - address to send withdrawn underlying to
    /// @return amount of underlying withdrawn
    function claimFromVaultAsCvx(
        uint256 amount,
        uint256 minAmountOut,
        address to
    ) public notToZeroAddress(to) returns (uint256) {
        _claimAndWithdraw(amount);
        return
            _claimAsCvx(
                IERC20(PXCVX_TOKEN).balanceOf(address(this)),
                minAmountOut,
                to
            );
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
        require(_ethAmount >= minAmountOut, "slippage");
        (bool success, ) = to.call{value: _ethAmount}("");
        require(success, "ETH transfer failed");
        return _ethAmount;
    }

    /// @notice Withdraw as native ETH (internal)
    /// @param _amount - amount to withdraw
    /// @return amount of ETH withdrawn
    function _claimAsEth(uint256 _amount)
        public
        nonReentrant
        returns (uint256)
    {
        _claimAndWithdraw(_amount);
        uint256 _cvxAmount = _claimAsCvx(
            IERC20(PXCVX_TOKEN).balanceOf(address(this)),
            1,
            address(this)
        );
        return
            cvxEthSwap.exchange_underlying(
                CVXETH_CVX_INDEX,
                CVXETH_ETH_INDEX,
                _cvxAmount,
                0
            );
    }

    /// @notice Claim to any token via a univ2 router
    /// @notice Use at your own risk
    /// @param amount - amount to unstake
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
    /// @param amount - the amount to unstake
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

    /// @notice Withdraw as CRV (internal)
    /// @param _amount - amount to withdraw
    /// @param _minAmountOut - min amount received
    /// @return amount of CRV withdrawn
    function _claimAsCrv(uint256 _amount, uint256 _minAmountOut)
        internal
        returns (uint256)
    {
        uint256 _ethAmount = _claimAsEth(_amount);
        return _swapEthToCrv(_ethAmount, _minAmountOut);
    }

    /// @notice Claim as CRV
    /// @param amount - the amount to unstake
    /// @param minAmountOut - the min expected amount received
    /// @param to - receiver address
    /// @return amount obtained
    function claimFromVaultAsCrv(
        uint256 amount,
        uint256 minAmountOut,
        address to
    ) public notToZeroAddress(to) returns (uint256) {
        uint256 _crvAmount = _claimAsCrv(amount, minAmountOut);
        IERC20(CRV_TOKEN).safeTransfer(to, _crvAmount);
        return _crvAmount;
    }

    /// @notice Claim as cvxCRV
    /// @param amount - the amount to unstake
    /// @param minAmountOut - the min expected amount received
    /// @param to - receiver address
    /// @return amount obtained
    function claimFromVaultAsCvxCrv(
        uint256 amount,
        uint256 minAmountOut,
        address to
    ) public notToZeroAddress(to) returns (uint256) {
        uint256 _crvAmount = _claimAsCrv(amount, 0);
        return _swapCrvToCvxCrv(_crvAmount, to, minAmountOut);
    }

    /// @notice swap ETH to USDT via Curve's tricrypto
    /// @param _amount - the amount of ETH to swap
    /// @param _minAmountOut - the minimum amount expected
    function _swapEthToUsdt(uint256 _amount, uint256 _minAmountOut) internal {
        triCryptoSwap.exchange{value: _amount}(
            2, // ETH
            0, // USDT
            _amount,
            _minAmountOut,
            true
        );
    }

    receive() external payable {}
}