// SPDX-License-Identifier: MIT
/*
██████╗ ██╗     ██╗   ██╗███████╗██████╗ ███████╗██████╗ ██████╗ ██╗   ██╗
██╔══██╗██║     ██║   ██║██╔════╝██╔══██╗██╔════╝██╔══██╗██╔══██╗╚██╗ ██╔╝
██████╔╝██║     ██║   ██║█████╗  ██████╔╝█████╗  ██████╔╝██████╔╝ ╚████╔╝
██╔══██╗██║     ██║   ██║██╔══╝  ██╔══██╗██╔══╝  ██╔══██╗██╔══██╗  ╚██╔╝
██████╔╝███████╗╚██████╔╝███████╗██████╔╝███████╗██║  ██║██║  ██║   ██║
╚═════╝ ╚══════╝ ╚═════╝ ╚══════╝╚═════╝ ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝
*/

pragma solidity 0.8.16;

import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "./BasicSpell.sol";
import "../interfaces/ICurveOracle.sol";
import "../interfaces/IWConvexPools.sol";
import "../interfaces/curve/ICurvePool.sol";
import "../interfaces/uniswap/IUniswapV2Router02.sol";

/**
 * @title ConvexSpell
 * @author BlueberryProtocol
 * @notice ConvexSpell is the factory contract that
 * defines how Blueberry Protocol interacts with Convex pools
 */
contract ConvexSpell is BasicSpell {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    /// @dev Address to Wrapped Convex Pools
    IWConvexPools public wConvexPools;
    /// @dev address of CurveOracle
    ICurveOracle public crvOracle;
    /// @dev address of CVX token
    address public CVX;

    function initialize(
        IBank bank_,
        address werc20_,
        address weth_,
        address wConvexPools_,
        address crvOracle_
    ) external initializer {
        __BasicSpell_init(bank_, werc20_, weth_);
        if (wConvexPools_ == address(0) || crvOracle_ == address(0))
            revert Errors.ZERO_ADDRESS();

        wConvexPools = IWConvexPools(wConvexPools_);
        CVX = address(wConvexPools.CVX());
        crvOracle = ICurveOracle(crvOracle_);
        IWConvexPools(wConvexPools_).setApprovalForAll(address(bank_), true);
    }

    /**
     * @notice Add strategy to the spell
     * @param crvLp Address of crv lp token for given strategy
     * @param maxPosSize, USD price of maximum position size for given strategy, based 1e18
     */
    function addStrategy(address crvLp, uint256 maxPosSize) external onlyOwner {
        _addStrategy(crvLp, maxPosSize);
    }

    /**
     * @notice Add liquidity to Curve pool with 2 underlying tokens, with staking to Curve gauge
     * @param minLPMint Desired LP token amount (slippage control)
     */
    function openPositionFarm(
        OpenPosParam calldata param,
        uint256 minLPMint
    )
        external
        existingStrategy(param.strategyId)
        existingCollateral(param.strategyId, param.collToken)
    {
        Strategy memory strategy = strategies[param.strategyId];
        (address lpToken, , , , , ) = wConvexPools.getPoolInfoFromPoolId(
            param.farmingPoolId
        );
        if (strategy.vault != lpToken) revert Errors.INCORRECT_LP(lpToken);

        // 1. Deposit isolated collaterals on Blueberry Money Market
        _doLend(param.collToken, param.collAmount);

        // 2. Borrow specific amounts
        uint256 borrowBalance = _doBorrow(
            param.borrowToken,
            param.borrowAmount
        );

        // 3. Add liquidity on curve, get crvLp
        (address pool, address[] memory tokens, ) = crvOracle.getPoolInfo(
            lpToken
        );
        _ensureApprove(param.borrowToken, pool, borrowBalance);
        if (tokens.length == 2) {
            uint256[2] memory suppliedAmts;
            for (uint256 i = 0; i < 2; i++) {
                suppliedAmts[i] = IERC20Upgradeable(tokens[i]).balanceOf(
                    address(this)
                );
            }
            ICurvePool(pool).add_liquidity(suppliedAmts, minLPMint);
        } else if (tokens.length == 3) {
            uint256[3] memory suppliedAmts;
            for (uint256 i = 0; i < 3; i++) {
                suppliedAmts[i] = IERC20Upgradeable(tokens[i]).balanceOf(
                    address(this)
                );
            }
            ICurvePool(pool).add_liquidity(suppliedAmts, minLPMint);
        } else if (tokens.length == 4) {
            uint256[4] memory suppliedAmts;
            for (uint256 i = 0; i < 4; i++) {
                suppliedAmts[i] = IERC20Upgradeable(tokens[i]).balanceOf(
                    address(this)
                );
            }
            ICurvePool(pool).add_liquidity(suppliedAmts, minLPMint);
        }

        // 4. Validate MAX LTV
        _validateMaxLTV(param.strategyId);

        // 5. Validate Max Pos Size
        _validateMaxPosSize(param.strategyId);

        // 6. Take out existing collateral and burn
        IBank.Position memory pos = bank.getCurrentPositionInfo();
        if (pos.collateralSize > 0) {
            (uint256 pid, ) = wConvexPools.decodeId(pos.collId);
            if (param.farmingPoolId != pid)
                revert Errors.INCORRECT_PID(param.farmingPoolId);
            if (pos.collToken != address(wConvexPools))
                revert Errors.INCORRECT_COLTOKEN(pos.collToken);
            bank.takeCollateral(pos.collateralSize);
            wConvexPools.burn(pos.collId, pos.collateralSize);
            _doRefundRewards(CVX);
        }

        // 7. Deposit on Convex Pool, Put wrapped collateral tokens on Blueberry Bank
        uint256 lpAmount = IERC20Upgradeable(lpToken).balanceOf(address(this));
        _ensureApprove(lpToken, address(wConvexPools), lpAmount);
        uint256 id = wConvexPools.mint(param.farmingPoolId, lpAmount);
        bank.putCollateral(address(wConvexPools), id, lpAmount);
    }

    function closePositionFarm(
        ClosePosParam calldata param,
        IUniswapV2Router02 swapRouter,
        address[][] calldata swapPath
    )
        external
        existingStrategy(param.strategyId)
        existingCollateral(param.strategyId, param.collToken)
    {
        address crvLp = strategies[param.strategyId].vault;
        IBank.Position memory pos = bank.getCurrentPositionInfo();
        if (pos.collToken != address(wConvexPools))
            revert Errors.INCORRECT_COLTOKEN(pos.collToken);
        if (wConvexPools.getUnderlyingToken(pos.collId) != crvLp)
            revert Errors.INCORRECT_UNDERLYING(crvLp);

        // 1. Take out collateral - Burn wrapped tokens, receive crv lp tokens and harvest CRV
        bank.takeCollateral(param.amountPosRemove);
        (address[] memory rewardTokens, ) = wConvexPools.burn(
            pos.collId,
            param.amountPosRemove
        );

        // 2. Swap rewards tokens to debt token
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            uint256 rewards = _doCutRewardsFee(rewardTokens[i]);
            _ensureApprove(rewardTokens[i], address(swapRouter), rewards);
            swapRouter.swapExactTokensForTokens(
                rewards,
                0,
                swapPath[i],
                address(this),
                type(uint256).max
            );
        }

        {
            (address pool, address[] memory tokens, ) = crvOracle.getPoolInfo(
                crvLp
            );
            // 3. Calculate actual amount to remove
            uint256 amountPosRemove = param.amountPosRemove;
            if (amountPosRemove == type(uint256).max) {
                amountPosRemove = IERC20Upgradeable(crvLp).balanceOf(
                    address(this)
                );
            }

            // 4. Remove liquidity
            int128 tokenIndex;
            for (uint256 i = 0; i < tokens.length; i++) {
                if (tokens[i] == pos.debtToken) {
                    tokenIndex = int128(uint128(i));
                    break;
                }
            }

            ICurvePool(pool).remove_liquidity_one_coin(
                amountPosRemove,
                int128(tokenIndex),
                0
            );
        }

        // 5. Withdraw isolated collateral from Bank
        _doWithdraw(param.collToken, param.amountShareWithdraw);

        // 6. Repay
        {
            // Compute repay amount if MAX_INT is supplied (max debt)
            uint256 amountRepay = param.amountRepay;
            if (amountRepay == type(uint256).max) {
                amountRepay = bank.currentPositionDebt(bank.POSITION_ID());
            }
            _doRepay(param.borrowToken, amountRepay);
        }

        _validateMaxLTV(param.strategyId);

        // 7. Refund
        _doRefund(param.borrowToken);
        _doRefund(param.collToken);
        _doRefund(CVX);
    }
}