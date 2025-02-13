// SPDX-License-Identifier: MIT

pragma solidity 0.8.16;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";

import "./BasicSpell.sol";
import "../utils/BlueBerryConst.sol";
import "../libraries/UniV3/UniV3WrappedLibMockup.sol";
import "../interfaces/IOracle.sol";
import "../interfaces/IWIchiFarm.sol";
import "../interfaces/ichi/IICHIVault.sol";

contract IchiVaultSpell is BasicSpell, IUniswapV3SwapCallback {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    struct Strategy {
        address vault;
        uint256 maxPositionSize;
    }

    /// @dev temperory state used to store uni v3 pool when swapping on uni v3
    IUniswapV3Pool private swapPool;

    /// @dev strategyId => ichi vault
    Strategy[] public strategies;
    /// @dev strategyId => collateral token => maxLTV
    mapping(uint256 => mapping(address => uint256)) public maxLTV; // base 1e4
    /// @dev address of ICHI farm wrapper
    IWIchiFarm public wIchiFarm;
    /// @dev address of ICHI token
    address public ICHI;

    event StrategyAdded(uint256 strategyId, address vault, uint256 maxPosSize);
    event CollateralsSupportAdded(
        uint256 strategyId,
        address[] collaterals,
        uint256[] maxLTVs
    );

    modifier existingStrategy(uint256 strategyId) {
        if (strategyId >= strategies.length)
            revert STRATEGY_NOT_EXIST(address(this), strategyId);

        _;
    }

    modifier existingCollateral(uint256 strategyId, address col) {
        if (maxLTV[strategyId][col] == 0)
            revert COLLATERAL_NOT_EXIST(strategyId, col);

        _;
    }

    function initialize(
        IBank _bank,
        address _werc20,
        address _weth,
        address _wichiFarm
    ) external initializer {
        __BasicSpell_init(_bank, _werc20, _weth);

        wIchiFarm = IWIchiFarm(_wichiFarm);
        ICHI = address(wIchiFarm.ICHI());
        IWIchiFarm(_wichiFarm).setApprovalForAll(address(_bank), true);
    }

    /**
     * @notice Owner privileged function to add vault
     * @param vault Address of ICHI angel vault
     * @param maxPosSize, USD price based maximum size of a position for given vault, based 1e18
     */
    function addStrategy(address vault, uint256 maxPosSize) external onlyOwner {
        if (vault == address(0)) revert ZERO_ADDRESS();
        if (maxPosSize == 0) revert ZERO_AMOUNT();
        strategies.push(Strategy({vault: vault, maxPositionSize: maxPosSize}));
        emit StrategyAdded(strategies.length - 1, vault, maxPosSize);
    }

    function addCollateralsSupport(
        uint256 strategyId,
        address[] memory collaterals,
        uint256[] memory maxLTVs
    ) external existingStrategy(strategyId) onlyOwner {
        if (collaterals.length != maxLTVs.length || collaterals.length == 0)
            revert INPUT_ARRAY_MISMATCH();

        for (uint256 i = 0; i < collaterals.length; i++) {
            if (collaterals[i] == address(0)) revert ZERO_ADDRESS();
            if (maxLTVs[i] == 0) revert ZERO_AMOUNT();
            maxLTV[strategyId][collaterals[i]] = maxLTVs[i];
        }

        emit CollateralsSupportAdded(strategyId, collaterals, maxLTVs);
    }

    function _validateMaxLTV(uint256 strategyId) internal view {
        uint256 debtValue = bank.getDebtValue(bank.POSITION_ID());
        (, address collToken, uint256 collAmount, , , , , ) = bank
            .getCurrentPositionInfo();
        uint256 collPrice = bank.oracle().getPrice(collToken);
        uint256 collValue = (collPrice * collAmount) /
            10**IERC20Metadata(collToken).decimals();

        if (
            debtValue >
            (collValue * maxLTV[strategyId][collToken]) / DENOMINATOR
        ) revert EXCEED_MAX_LTV();
    }

    /**
     * @notice Internal function to deposit assets on ICHI Vault
     * @param collToken Isolated collateral token address
     * @param collAmount Amount of isolated collateral
     * @param borrowToken Token address to borrow
     * @param borrowAmount amount to borrow from Bank
     */
    function depositInternal(
        uint256 strategyId,
        address collToken,
        address borrowToken,
        uint256 collAmount,
        uint256 borrowAmount
    ) internal {
        Strategy memory strategy = strategies[strategyId];

        // 1. Lend isolated collaterals on compound
        doLend(collToken, collAmount);

        // 2. Borrow specific amounts
        doBorrow(borrowToken, borrowAmount);

        // 3. Add liquidity - Deposit on ICHI Vault
        IICHIVault vault = IICHIVault(strategy.vault);
        bool isTokenA = vault.token0() == borrowToken;
        uint256 balance = IERC20(borrowToken).balanceOf(address(this));
        ensureApprove(borrowToken, address(vault));
        if (isTokenA) {
            vault.deposit(balance, 0, address(this));
        } else {
            vault.deposit(0, balance, address(this));
        }

        // 4. Validate MAX LTV
        _validateMaxLTV(strategyId);

        // 5. Validate Max Pos Size
        uint256 lpPrice = bank.oracle().getPrice(strategy.vault);
        uint256 curPosSize = (lpPrice * vault.balanceOf(address(this))) /
            10**IICHIVault(strategy.vault).decimals();
        if (curPosSize > strategy.maxPositionSize)
            revert EXCEED_MAX_POS_SIZE(strategyId);
    }

    /**
     * @notice External function to deposit assets on IchiVault
     * @param collToken Collateral Token address to deposit (e.g USDC)
     * @param collAmount Amount of user's collateral (e.g USDC)
     * @param borrowToken Address of token to borrow
     * @param borrowAmount Amount to borrow from Bank
     */
    function openPosition(
        uint256 strategyId,
        address collToken,
        address borrowToken,
        uint256 collAmount,
        uint256 borrowAmount
    )
        external
        existingStrategy(strategyId)
        existingCollateral(strategyId, collToken)
    {
        // 1-3 Deposit on ichi vault
        depositInternal(
            strategyId,
            collToken,
            borrowToken,
            collAmount,
            borrowAmount
        );

        // 4. Put collateral - ICHI Vault Lp Token
        address vault = strategies[strategyId].vault;
        doPutCollateral(vault, IERC20(vault).balanceOf(address(this)));
    }

    /**
     * @notice External function to deposit assets on IchiVault and farm in Ichi Farm
     * @param collToken Collateral Token address to deposit (e.g USDC)
     * @param collAmount Amount of user's collateral (e.g USDC)
     * @param borrowToken Address of token to borrow
     * @param borrowAmount Amount to borrow from Bank
     * @param farmingPid Pool Id of vault lp on ICHI Farm
     */
    function openPositionFarm(
        uint256 strategyId,
        address collToken,
        address borrowToken,
        uint256 collAmount,
        uint256 borrowAmount,
        uint256 farmingPid
    )
        external
        existingStrategy(strategyId)
        existingCollateral(strategyId, collToken)
    {
        Strategy memory strategy = strategies[strategyId];
        address lpToken = wIchiFarm.ichiFarm().lpToken(farmingPid);
        if (strategy.vault != lpToken) revert INCORRECT_LP(lpToken);

        // 1-3 Deposit on ichi vault
        depositInternal(
            strategyId,
            collToken,
            borrowToken,
            collAmount,
            borrowAmount
        );

        // 4. Take out collateral
        (
            ,
            ,
            ,
            ,
            address posCollToken,
            uint256 collId,
            uint256 collSize,

        ) = bank.getCurrentPositionInfo();
        if (collSize > 0) {
            (uint256 decodedPid, ) = wIchiFarm.decodeId(collId);
            if (farmingPid != decodedPid) revert INCORRECT_PID(farmingPid);
            if (posCollToken != address(wIchiFarm))
                revert INCORRECT_COLTOKEN(posCollToken);
            bank.takeCollateral(collSize);
            wIchiFarm.burn(collId, collSize);
        }

        // 5. Deposit on farming pool, put collateral
        ensureApprove(strategy.vault, address(wIchiFarm));
        uint256 lpAmount = IERC20(strategy.vault).balanceOf(address(this));
        uint256 id = wIchiFarm.mint(farmingPid, lpAmount);
        bank.putCollateral(address(wIchiFarm), id, lpAmount);
    }

    /**
     * @dev Increase isolated collateral of position
     * @param token Isolated collateral token address
     * @param amount Amount of token to increase position
     */
    function increasePosition(address token, uint256 amount) external {
        // 1. Get user input amounts
        doLend(token, amount);
    }

    /**
     * @dev Reduce isolated collateral of position
     * @param collToken Isolated collateral token address
     * @param collAmount Amount of Isolated collateral
     */
    function reducePosition(
        uint256 strategyId,
        address collToken,
        uint256 collAmount
    ) external {
        doWithdraw(collToken, collAmount);
        doRefund(collToken);
        _validateMaxLTV(strategyId);
    }

    function withdrawInternal(
        uint256 strategyId,
        address collToken,
        address borrowToken,
        uint256 amountRepay,
        uint256 amountLpWithdraw,
        uint256 amountShareWithdraw
    ) internal {
        Strategy memory strategy = strategies[strategyId];
        IICHIVault vault = IICHIVault(strategy.vault);
        uint256 positionId = bank.POSITION_ID();

        // 1. Compute repay amount if MAX_INT is supplied (max debt)
        if (amountRepay == type(uint256).max) {
            amountRepay = bank.borrowBalanceCurrent(positionId, borrowToken);
        }

        // 2. Calculate actual amount to remove
        uint256 amtLPToRemove = vault.balanceOf(address(this)) -
            amountLpWithdraw;

        // 3. Withdraw liquidity from ICHI vault
        vault.withdraw(amtLPToRemove, address(this));

        // 4. Swap withdrawn tokens to initial deposit token
        bool isTokenA = vault.token0() == borrowToken;
        uint256 amountToSwap = IERC20(
            isTokenA ? vault.token1() : vault.token0()
        ).balanceOf(address(this));
        if (amountToSwap > 0) {
            swapPool = IUniswapV3Pool(vault.pool());
            swapPool.swap(
                address(this),
                // if withdraw token is Token0, then swap token1 -> token0 (false)
                !isTokenA,
                int256(amountToSwap),
                isTokenA
                    ? UniV3WrappedLibMockup.MAX_SQRT_RATIO - 1 // Token0 -> Token1
                    : UniV3WrappedLibMockup.MIN_SQRT_RATIO + 1, // Token1 -> Token0
                abi.encode(address(this))
            );
        }

        // 5. Withdraw isolated collateral from Bank
        doWithdraw(collToken, amountShareWithdraw);

        // 6. Repay
        doRepay(borrowToken, amountRepay);

        _validateMaxLTV(strategyId);

        // 7. Refund
        doRefund(borrowToken);
        doRefund(collToken);
    }

    /**
     * @notice External function to withdraw assets from ICHI Vault
     * @param collToken Token address to withdraw (e.g USDC)
     * @param borrowToken Token address to withdraw (e.g USDC)
     * @param lpTakeAmt Amount of ICHI Vault LP token to take out from Bank
     * @param amountRepay Amount to repay the loan
     * @param amountLpWithdraw Amount of ICHI Vault LP to withdraw from ICHI Vault
     * @param amountShareWithdraw Amount of Isolated collateral to withdraw from Compound
     */
    function closePosition(
        uint256 strategyId,
        address collToken,
        address borrowToken,
        uint256 lpTakeAmt,
        uint256 amountRepay,
        uint256 amountLpWithdraw,
        uint256 amountShareWithdraw
    )
        external
        existingStrategy(strategyId)
        existingCollateral(strategyId, collToken)
    {
        // 1. Take out collateral
        doTakeCollateral(strategies[strategyId].vault, lpTakeAmt);

        withdrawInternal(
            strategyId,
            collToken,
            borrowToken,
            amountRepay,
            amountLpWithdraw,
            amountShareWithdraw
        );
    }

    function closePositionFarm(
        uint256 strategyId,
        address collToken,
        address borrowToken,
        uint256 lpTakeAmt,
        uint256 amountRepay,
        uint256 amountLpWithdraw,
        uint256 amountShareWithdraw
    )
        external
        existingStrategy(strategyId)
        existingCollateral(strategyId, collToken)
    {
        address vault = strategies[strategyId].vault;
        (, , , , address posCollToken, uint256 collId, , ) = bank
            .getCurrentPositionInfo();
        if (IWIchiFarm(posCollToken).getUnderlyingToken(collId) != vault)
            revert INCORRECT_UNDERLYING(vault);
        if (posCollToken != address(wIchiFarm))
            revert INCORRECT_COLTOKEN(posCollToken);

        // 1. Take out collateral
        bank.takeCollateral(lpTakeAmt);
        wIchiFarm.burn(collId, lpTakeAmt);
        doCutRewardsFee(ICHI);

        // 2-8. Remove liquidity
        withdrawInternal(
            strategyId,
            collToken,
            borrowToken,
            amountRepay,
            amountLpWithdraw,
            amountShareWithdraw
        );

        // 9. Refund ichi token
        doRefund(ICHI);
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external override {
        if (msg.sender != address(swapPool)) revert NOT_FROM_UNIV3(msg.sender);
        address payer = abi.decode(data, (address));

        if (amount0Delta > 0) {
            if (payer == address(this)) {
                IERC20Upgradeable(swapPool.token0()).safeTransfer(
                    msg.sender,
                    uint256(amount0Delta)
                );
            } else {
                IERC20Upgradeable(swapPool.token0()).safeTransferFrom(
                    payer,
                    msg.sender,
                    uint256(amount0Delta)
                );
            }
        } else if (amount1Delta > 0) {
            if (payer == address(this)) {
                IERC20Upgradeable(swapPool.token1()).safeTransfer(
                    msg.sender,
                    uint256(amount1Delta)
                );
            } else {
                IERC20Upgradeable(swapPool.token1()).safeTransferFrom(
                    payer,
                    msg.sender,
                    uint256(amount1Delta)
                );
            }
        }
    }
}