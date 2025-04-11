// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";
import {ILendingPool} from "./interfaces/ILendingPool.sol";
import {IMainnetRouter} from "./interfaces/IMainnetRouter.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";
import {Path} from "./libraries/Path.sol";
import {ILeverager} from "./interfaces/ILeverager.sol";

/// @title Leverager
/// @author deadrosesxyz

contract Leverager is ReentrancyGuard, Ownable, ERC721, ILeverager {
    using SafeERC20 for IERC20;
    using Path for bytes;

    /// @notice The lending pool from which funds are borrowed/ repaid to
    address immutable lendingPool;

    /// @notice The precision used when dealing with pool's TWAP price.
    uint256 constant PRECISION = 1e30;

    /// @notice The next position id. Ids start from 1.
    uint256 id = 1;

    /// @notice Returns the corresponding position, based on the id provided.
    mapping(uint256 => Position) public positions;

    /// @notice Returns the VaultParams, based on the vault provided
    mapping(address => VaultParams) public vaultParams;

    /// @notice The pricefeed used to fetch token prices
    address public pricefeed;

    /// @notice The swap router through which swaps are performed
    address public swapRouter;

    /// @notice The protocol fee recipient.
    address public feeRecipient;

    /// @notice The protocol fee charged upon successful liquidation
    /// @notice It is taken based on the profit of the liquidation.
    uint256 liquidationFee;

    /// @notice The minimum borrowed amount
    uint256 minBorrow = 20e18;

    /// @notice Sets the name, symbol and lending pool
    /// @param name_ Name of the ERC721
    /// @param symbol_ Symbol of the ERC721
    /// @param _lendingPool The address of the lending pool
    constructor(string memory name_, string memory symbol_, address _lendingPool)
        Ownable(msg.sender)
        ERC721(name_, symbol_)
    {
        lendingPool = _lendingPool;
    }

    /// @notice Owner-only function which enables leveraged positions for a specified vault
    /// @param vault Vault to enable leverage on
    /// @param _maxUsdLeverage Max amount of USD that can be borrowed in a single position
    /// @param _maxTimesLeverage Max leverage at which a position can be opened
    /// @param collatPct Minimum percentage of collateral which must remain before position becomes liquidateable
    /// @param _maxCumulativeBorrowUSD The maximum cumulative borrows possible for a vault. Denominated in USD.
    /// @dev For simplicity, all of the borrows are valued at the time of opening the position.
    /// @dev In case the value is significantly off, governance can adjust the cap accordingly, without causing any issues.
    function initVault(
        address vault,
        uint256 _maxUsdLeverage,
        uint256 _maxTimesLeverage,
        uint256 collatPct,
        uint256 _maxCumulativeBorrowUSD
    ) external onlyOwner {
        require(!vaultParams[vault].leverageEnabled, "already enabled");
        vaultParams[vault].leverageEnabled = true;
        vaultParams[vault].maxUsdLeverage = _maxUsdLeverage;
        vaultParams[vault].maxTimesLeverage = _maxTimesLeverage;
        vaultParams[vault].minCollateralPct = collatPct;
        vaultParams[vault].maxCumulativeBorrowedUSD = _maxCumulativeBorrowUSD;

        address token0 = IVault(vault).token0();
        address token1 = IVault(vault).token1();

        IERC20(token0).forceApprove(vault, type(uint256).max);
        IERC20(token1).forceApprove(vault, type(uint256).max);
        IERC20(token0).forceApprove(lendingPool, type(uint256).max);
        IERC20(token1).forceApprove(lendingPool, type(uint256).max);
    }

    /// @notice Opens up a leveraged position within a certain Vault.
    /// @dev Check the ILeverager contract for comments on all LeverageParams arguments
    /// In order to achieve this, contract first "flashloans" funds from the lending pool to open a position
    /// Then, it borrows the denomination token and performs swaps (if necessary)
    /// Any unused borrowed tokens, as well as flashloaned tokens are then repaid.
    function openLeveragedPosition(LeverageParams calldata lp) external nonReentrant returns (uint256 _id) {
        require(vaultParams[lp.vault].leverageEnabled, "leverage not enabled");

        Position memory up;
        up.token0 = IVault(lp.vault).token0();
        up.token1 = IVault(lp.vault).token1();
        up.vault = lp.vault;

        // we check the activity here, in order to make sure TWAP price is accurate
        // TWAP lags behind, so if we don't check, attacker might utilize old price
        uint256 price = IVault(lp.vault).twapPrice();
        require(IVault(lp.vault).checkPoolActivity(), "market too volatile");

        IERC20(up.token0).safeTransferFrom(msg.sender, address(this), lp.amount0In);
        IERC20(up.token1).safeTransferFrom(msg.sender, address(this), lp.amount1In);

        uint256 delta0 = lp.vault0In - lp.amount0In;
        uint256 delta1 = lp.vault1In - lp.amount1In;
        if (delta0 > 0) ILendingPool(lendingPool).pullFunds(up.token0, delta0); // we flashloan the difference between amounts desired to be deposited in Vault
        if (delta1 > 0) ILendingPool(lendingPool).pullFunds(up.token1, delta1); // and the amount pulled from the user

        // a0 and a1 represent the actual amounts deposited within the vault.
        // We keep track of them as we later make exactOutput swaps based on them
        (uint256 shares, uint256 a0, uint256 a1) =
            IVault(lp.vault).deposit(lp.vault0In, lp.vault1In, lp.min0in, lp.min1in);

        up.initCollateralUsd = _calculateTokenValues(up.token0, up.token1, a0, a1, price); // returns the USD price in 1e18
        uint256 bPrice = IPriceFeed(pricefeed).getPrice(lp.denomination);
        up.initCollateralValue = up.initCollateralUsd * (10 ** ERC20(lp.denomination).decimals()) / bPrice;

        {
            // we first borrow the maximum amount the user is willing to borrow. Any unused within the swaps is later repaid.
            ILendingPool(lendingPool).borrow(lp.denomination, lp.maxBorrowAmount);

            IMainnetRouter.ExactOutputParams memory swapParams;

            // Only important thing to verify here is that the tokenIn is NOT a vault share token.
            // Otherwise, attacker could utilize this to swap out all of the share tokens out of here.
            // We do not verify here that the output tokens is one of the lp tokens. If for some reason it isn't
            // The transaction will later revert within `pushFunds`
            if (a0 > lp.amount0In && up.token0 != lp.denomination) {
                swapParams = abi.decode(lp.swapParams1, (IMainnetRouter.ExactOutputParams));

                address tokenIn = _getTokenIn(swapParams.path);
                require(tokenIn == lp.denomination, "token should be denomination");

                IERC20(tokenIn).forceApprove(swapRouter, swapParams.amountInMaximum);

                swapParams.amountOut = a0 - lp.amount0In;
                IMainnetRouter(swapRouter).exactOutput(swapParams);
                IERC20(tokenIn).forceApprove(swapRouter, 0);
            }

            if (a1 > lp.amount1In && up.token1 != lp.denomination) {
                swapParams = abi.decode(lp.swapParams2, (IMainnetRouter.ExactOutputParams));
                address tokenIn = _getTokenIn(swapParams.path);
                require(tokenIn == lp.denomination, "token should be denomination 2 ");
                IERC20(tokenIn).forceApprove(swapRouter, swapParams.amountInMaximum);

                swapParams.amountOut = a1 - lp.amount1In;
                IMainnetRouter(swapRouter).exactOutput(swapParams);
                IERC20(tokenIn).forceApprove(swapRouter, 0);
            }
        }

        if (delta0 > 0) ILendingPool(lendingPool).pushFunds(up.token0, delta0);
        if (delta1 > 0) ILendingPool(lendingPool).pushFunds(up.token1, delta1);

        uint256 denomBalance = IERC20(lp.denomination).balanceOf(address(this));
        ILendingPool(lendingPool).repay(lp.denomination, denomBalance);

        // if for some reason there have previously been a large amount of tokens "stuck", this could fail
        // this is ok as 1) its unlikely 2) anyone could sweep them 3) likely MEV bot would sweep them within seconds
        // Although opening positions is time-sensitive, please do not report this as a vulnerability, ty.
        up.borrowedAmount = lp.maxBorrowAmount - denomBalance;
        up.initBorrowedUsd = up.borrowedAmount * bPrice / (10 ** ERC20(lp.denomination).decimals());

        up.borrowedIndex = ILendingPool(lendingPool).getCurrentBorrowingIndex(lp.denomination);
        up.denomination = lp.denomination;
        up.shares = shares;
        up.vault = lp.vault;

        vaultParams[lp.vault].currBorrowedUSD += up.initBorrowedUsd;
        _checkWithinlimits(up);

        _id = id++;
        positions[_id] = up;

        // here we check whether the position is liquidateable, as for positions with over 2x leverage
        // user could swap the all of the denom tokens for pretty much nothing in return
        // (sandwiching the tx himself). This way they'd steal the borrowed tokens and create
        // underwater position, which would force governance to liquidate it at a loss.
        require(!isLiquidateable(_id), "position can't be liquidateable upon opening");

        _mint(msg.sender, _id);
        _sweepTokens(up.token0, up.token1);

        return _id;
    }

    /// @notice Withdraws a certain percentage of a user's leveraged position.
    /// @dev Check the ILeverager contract for comments on all WithdrawParams arguments
    /// If the position does not hold enough of denomination token (or simply neither of the tokens is denomination token)
    /// The necessary amount is pulled from the user. For this reason, provided swapParams should have the user as recipient.
    /// @dev We do not check whether position is liquidateable as we remove collateral and repay debt
    /// in the same ratio as the position currently is.
    function withdraw(WithdrawParams calldata wp) external nonReentrant {
        Position memory up = positions[wp.id];
        require(_isApprovedOrOwner(msg.sender, wp.id), "msg.sender not approved or owner");
        require(wp.pctWithdraw <= 1e18 && wp.pctWithdraw > 0.01e18, "invalid pctWithdraw");

        address borrowed = up.denomination;
        uint256 sharesToWithdraw = up.shares * wp.pctWithdraw / 1e18;

        (uint256 amountOut0, uint256 amountOut1) =
            IVault(up.vault).withdraw(sharesToWithdraw, wp.minAmount0, wp.minAmount1);

        uint256 bIndex = ILendingPool(lendingPool).getCurrentBorrowingIndex(borrowed);
        uint256 totalOwedAmount = up.borrowedAmount * bIndex / up.borrowedIndex;
        uint256 owedAmount = totalOwedAmount * wp.pctWithdraw / 1e18;

        uint256 amountToRepay = owedAmount; // this should be transferred to yAsset

        // In case either of the tokens is denomination token, we directly take from it.
        if (borrowed == up.token0) {
            uint256 repayFromWithdraw = amountOut0 < owedAmount ? amountOut0 : owedAmount;
            owedAmount -= repayFromWithdraw;
            amountOut0 -= repayFromWithdraw;
        } else if (borrowed == up.token1) {
            uint256 repayFromWithdraw = amountOut1 < owedAmount ? amountOut0 : owedAmount;
            owedAmount -= repayFromWithdraw;
            amountOut1 -= repayFromWithdraw;
        }

        if (wp.hasToSwap) {
            // ideally, these swaps should have the user as a recipient. Then, we'll just pull the necessary part from them.

            IMainnetRouter.ExactInputParams memory swapParams =
                abi.decode(wp.swapParams1, (IMainnetRouter.ExactInputParams));
            if (swapParams.amountIn > 0) {
                (address tokenIn,,) = swapParams.path.decodeFirstPool();
                require(tokenIn == up.token0, "swap input should be token0");
                IERC20(up.token0).forceApprove(swapRouter, swapParams.amountIn);

                // might be good here to set amountIn to the lower of swapParams.amountIn and amountOut0
                IMainnetRouter(swapRouter).exactInput(swapParams); // does not support sqrtPriceLimit. Do not use it, or you'd risk funds getting stuck.
                amountOut0 -= swapParams.amountIn;
            }

            swapParams = abi.decode(wp.swapParams2, (IMainnetRouter.ExactInputParams));
            if (swapParams.amountIn > 0) {
                (address tokenIn,,) = swapParams.path.decodeFirstPool();
                require(tokenIn == up.token1, "swap input should be token1");
                IERC20(up.token1).forceApprove(swapRouter, swapParams.amountIn);

                IMainnetRouter(swapRouter).exactInput(swapParams); // does not support sqrtPriceLimit. Do not use it, or you'd risk funds getting stuck.
                amountOut1 -= swapParams.amountIn;
            }
        }

        if (owedAmount > 0) IERC20(up.denomination).safeTransferFrom(msg.sender, address(this), owedAmount);

        ILendingPool(lendingPool).repay(borrowed, amountToRepay);

        if (amountOut0 > 0) IERC20(up.token0).safeTransfer(msg.sender, amountOut0);
        if (amountOut1 > 0) IERC20(up.token1).safeTransfer(msg.sender, amountOut1);

        if (wp.pctWithdraw == 1e18) {
            vaultParams[up.vault].currBorrowedUSD -= up.initBorrowedUsd;
            delete positions[wp.id];
            _burn(wp.id);
        } else {
            // Here, it doesn't matter that the initBorrowedUsd doesn't represent the real value. The scenarios are 2:
            // 1) Price has dropped. In this case, this would allow the user to actually have less than minBorrow opened,
            // but since borrowed asset's price has dropped, position is less likely to be liquidated
            // 2) Price has increased. In this case the user has to remain higher position value.
            require(
                up.initBorrowedUsd * (1e18 - wp.pctWithdraw) / 1e18 > minBorrow,
                "remaining should be at least minBorrow"
            );

            // here the BorrowedUSD variables do not represent the current value of the borrowed asset, that's intentional.
            vaultParams[up.vault].currBorrowedUSD -= up.initBorrowedUsd * wp.pctWithdraw / 1e18;

            positions[wp.id].initBorrowedUsd -= up.initBorrowedUsd * wp.pctWithdraw / 1e18;
            positions[wp.id].initCollateralValue -= up.initCollateralValue * wp.pctWithdraw / 1e18;
            positions[wp.id].borrowedAmount = totalOwedAmount - amountToRepay;
            positions[wp.id].borrowedIndex = bIndex;
            positions[wp.id].shares -= sharesToWithdraw;
        }
    }

    /// @notice Liquidates a certain leveraged position.
    /// @dev Check the ILeverager contract for comments on all LiquidateParams arguments
    /// @dev Does not support partial liquidations
    /// @dev Collects fees first, in order to properly calculate whether a position is actually liquidateable
    function liquidatePosition(LiquidateParams calldata liqParams) external collectFees(liqParams.id) nonReentrant {
        Position memory up = positions[liqParams.id];

        require(isLiquidateable(liqParams.id), "isnt liquidateable");

        uint256 currBIndex = ILendingPool(lendingPool).getCurrentBorrowingIndex(up.denomination);
        uint256 owedAmount = up.borrowedAmount * currBIndex / up.borrowedIndex;
        uint256 repayAmount = owedAmount;

        uint256 price = IVault(up.vault).twapPrice();
        // we do not check here for pool activity, in order to be able to liquidate during very volatile markets
        // otherwise, we'd risk accruing bad debt.

        (uint256 amount0, uint256 amount1) =
            IVault(up.vault).withdraw(up.shares, liqParams.minAmount0, liqParams.minAmount1);

        uint256 totalValueUSD = _calculateTokenValues(up.token0, up.token1, amount0, amount1, price);

        uint256 bPrice = IPriceFeed(pricefeed).getPrice(up.denomination);
        uint256 borrowedValue = owedAmount * bPrice / ERC20(up.denomination).decimals();

        if (totalValueUSD > borrowedValue) {
            // What % of the amountsOut are profit is calculated by `(totalValueUSD - borrowedUSD) / totalValueUSD`
            // Then, on top of that, we calculate the protocol fee and scale it in 1e18.

            uint256 protocolFeePct = 1e18 * liquidationFee * (totalValueUSD - borrowedValue) / (totalValueUSD * 10_000);
            uint256 pf0 = protocolFeePct * amount0 / 1e18;
            uint256 pf1 = protocolFeePct * amount1 / 1e18;

            if (pf0 > 0) IERC20(up.token0).safeTransfer(feeRecipient, pf0);
            if (pf1 > 0) IERC20(up.token1).safeTransfer(feeRecipient, pf1);
            amount0 -= pf0;
            amount1 -= pf1;
        }

        if (up.denomination == up.token0) {
            uint256 repayFromWithdraw = amount0 < owedAmount ? amount0 : owedAmount;
            owedAmount -= repayFromWithdraw;
            amount0 -= repayFromWithdraw;
        }

        if (up.denomination == up.token1) {
            uint256 repayFromWithdraw = amount1 < owedAmount ? amount1 : owedAmount;
            owedAmount -= repayFromWithdraw;
            amount1 -= repayFromWithdraw;
        }

        if (liqParams.hasToSwap) {
            // ideally, these swaps should have the user as a recipient. Then, we'll just pull the necessary part from them.

            IMainnetRouter.ExactInputParams memory swapParams =
                abi.decode(liqParams.swapParams1, (IMainnetRouter.ExactInputParams));
            if (swapParams.amountIn > 0) {
                (address tokenIn,,) = swapParams.path.decodeFirstPool();
                require(tokenIn == up.token0, "tokenIn should be token0");
                IERC20(up.token0).forceApprove(swapRouter, swapParams.amountIn);
                IMainnetRouter(swapRouter).exactInput(swapParams); // does not support sqrtPriceLimit
                amount0 -= swapParams.amountIn;
            }

            swapParams = abi.decode(liqParams.swapParams2, (IMainnetRouter.ExactInputParams));
            if (swapParams.amountIn > 0) {
                (address tokenIn,,) = swapParams.path.decodeFirstPool();
                require(tokenIn == up.token1, "tokenIn should be token0");
                IERC20(up.token1).forceApprove(swapRouter, swapParams.amountIn);
                IMainnetRouter(swapRouter).exactInput(swapParams); // does not support sqrtPriceLimit
                amount1 -= swapParams.amountIn;
            }
        }

        IERC20(up.denomination).safeTransferFrom(msg.sender, address(this), owedAmount);

        ILendingPool(lendingPool).repay(up.denomination, repayAmount);

        if (amount0 > 0) IERC20(up.token0).safeTransfer(msg.sender, amount0);
        if (amount1 > 0) IERC20(up.token1).safeTransfer(msg.sender, amount1);

        vaultParams[up.vault].currBorrowedUSD -= up.initBorrowedUsd;

        _burn(liqParams.id);
        delete positions[liqParams.id];
    }

    /// @notice Checks whether a certain position is liquidateable
    /// @dev In order to be 100% accurate, expects Strategy.collectFees to have been called right before that
    /// @param _id The id of the position
    function isLiquidateable(uint256 _id) public view returns (bool liquidateable) {
        Position memory pos = positions[_id];
        VaultParams memory vp = vaultParams[pos.vault];

        uint256 vaultSupply = IVault(pos.vault).totalSupply();

        // Assuming a price of X, a LP position has its lowest value when the pool price is exactly X.
        // Any price movement, would actually overvalue the position.
        // For this reason, attackers cannot force a position to become liquidateable with a swap.
        (uint256 vaultBal0, uint256 vaultBal1) = IVault(pos.vault).balances();
        uint256 userBal0 = pos.shares * vaultBal0 / vaultSupply;
        uint256 userBal1 = pos.shares * vaultBal1 / vaultSupply;
        uint256 price = IVault(pos.vault).twapPrice();

        uint256 totalValueUSD = _calculateTokenValues(pos.token0, pos.token1, userBal0, userBal1, price);
        uint256 bPrice = IPriceFeed(pricefeed).getPrice(pos.denomination);
        uint256 totalDenom = totalValueUSD * (10 ** ERC20(pos.denomination).decimals()) / bPrice;

        uint256 bIndex = ILendingPool(lendingPool).getCurrentBorrowingIndex(pos.denomination);
        uint256 owedAmount = pos.borrowedAmount * bIndex / pos.borrowedIndex;

        /// here we make a calculation what would be the necessary collateral
        /// if we had the same borrowed amount, but at max leverage. Check docs for better explanation why.
        uint256 base = owedAmount * 1e18 / (vp.maxTimesLeverage - 1e18);
        base = base < pos.initCollateralValue ? base : pos.initCollateralValue;

        if (owedAmount > totalDenom || totalDenom - owedAmount < vp.minCollateralPct * base / 1e18) return true;
        else return false;
    }

    /// @notice Calculates the USD value of amount0 and amount1
    /// @dev Requires at least one of them to have set a trustworthy pricefeed.
    /// If one of them doesn't have a pricefeed, it uses the pool TWAP price to convert said token to the other one.
    /// @param token0 The address of the first token
    /// @param token1 The address of the second token
    /// @param amount0 The amount of token0
    /// @param amount1 The amount of token1
    /// @param price The TWAP token0/token1 price.
    /// @return usdValue The total token value, denominated in USD, scaled in 1e18.
    function _calculateTokenValues(address token0, address token1, uint256 amount0, uint256 amount1, uint256 price)
        internal
        view
        returns (uint256 usdValue)
    {
        uint256 chPrice0;
        uint256 chPrice1;
        uint256 decimals0 = 10 ** ERC20(token0).decimals();
        uint256 decimals1 = 10 ** ERC20(token1).decimals();
        if (IPriceFeed(pricefeed).hasPriceFeed(token0)) {
            chPrice0 = IPriceFeed(pricefeed).getPrice(token0);
            usdValue += amount0 * chPrice0 / decimals0;
        }
        if (IPriceFeed(pricefeed).hasPriceFeed(token1)) {
            chPrice1 = IPriceFeed(pricefeed).getPrice(token1);
            usdValue += amount1 * chPrice1 / decimals1;
        }

        // If chPrice0 is 0, it means token0 doesnt have a pricefeed.
        // Therefore, convert it token1 and from there, convert it to USD
        if (chPrice0 == 0) {
            usdValue += (amount0 * price / PRECISION) * chPrice1 / decimals1;
        } else if (chPrice1 == 0) {
            usdValue += amount1 * PRECISION / price * chPrice0 / decimals0;
        }

        return usdValue;
    }

    /// @notice Checks that the position is within predefined limits.
    /// @dev Position has to:
    /// 1) Be at least minBorrow
    /// 2) Be within Vault's max USD borrow/ max leverage
    /// 3) Be within Asset's max borrow/ max leverage
    /// 4) Not result in Vault exceeding its max cumulative USD borrows.
    function _checkWithinlimits(Position memory up) internal {
        VaultParams memory vp = vaultParams[up.vault];
        (uint256 maxIndividualBorrow, uint256 maxLevTimes) =
            ILendingPool(lendingPool).getLeverageParams(up.denomination);

        uint256 positionLeverage = (up.initCollateralValue + up.borrowedAmount) * 1e18 / up.initCollateralValue;

        require(up.initBorrowedUsd >= minBorrow, "position must be at least minBorrow amount");
        require(positionLeverage <= vp.maxTimesLeverage && positionLeverage <= maxLevTimes, "too high x leverage");
        require(up.initBorrowedUsd <= vp.maxUsdLeverage, "too high borrow usd amount");
        require(up.borrowedAmount <= maxIndividualBorrow, "too high borrow for the vault");
        require(
            vaultParams[up.vault].currBorrowedUSD <= vaultParams[up.vault].maxCumulativeBorrowedUSD,
            "vault exceeded borrow limit"
        );
    }

    /// @notice Sweeps any leftover tokens and sends them to msg.sender
    /// @param token0 The first token to sweep
    /// @param token1 The second token to sweep
    /// @dev In some cases, a user might use less tokens in their leverage position
    /// Than they've intended to transfer from themselves (lp.amount0In).
    /// In this case, if the token is not denomination token, it would otherwise
    /// Remain within this contract. This function is created for this specific edge case
    /// @dev It is CRUCIAL that this function can never be called with one of the tokens being a vault share token.
    function _sweepTokens(address token0, address token1) internal {
        uint256 bal = IERC20(token0).balanceOf(address(this));
        if (bal > 0) IERC20(token0).safeTransfer(msg.sender, bal);

        bal = IERC20(token1).balanceOf(address(this));
        if (bal > 0) IERC20(token1).safeTransfer(msg.sender, bal);
    }

    /// @notice Collects fees within a certain position's strategy.
    /// @dev Needs to be called before checking if a position is liquidateable
    modifier collectFees(uint256 _id) {
        Position memory up = positions[_id];
        address strat = IVault(up.vault).strategy();
        IStrategy(strat).collectFees();
        _;
    }

    // --- Owner only functions

    /// @notice Allows users to borrow a certain token from the LendingPool.
    /// @param asset Asset to be enabled for borrows.
    /// @dev Needs to be called for a token in case no enabled vault has it one of its underlying tokens.
    function enableTokenAsBorrowed(address asset) external onlyOwner {
        IERC20(asset).forceApprove(lendingPool, type(uint256).max);
    }

    /// @notice Sets the liquidation fee
    /// @param newFee The new liquidation fee.
    function setLiquidationFee(uint256 newFee) external onlyOwner {
        require(newFee <= 10_000, "new fee too high");
        liquidationFee = newFee;
    }

    /// @notice Changes a Vault's max individual borrow
    function changeVaultMaxBorrow(address vault, uint256 maxBorrow) external onlyOwner {
        VaultParams storage vp = vaultParams[vault];
        vp.maxUsdLeverage = maxBorrow;
    }

    /// @notice Changes a Vault's max leverage allowed.
    function changeVaultMaxLeverage(address vault, uint256 maxLeverage) external onlyOwner {
        VaultParams storage vp = vaultParams[vault];
        vp.maxTimesLeverage = maxLeverage;
    }

    /// @notice Changes a vault's minimum collateral percentage
    function changeVaultMinCollateralPct(address vault, uint256 minColateral) external onlyOwner {
        VaultParams storage vp = vaultParams[vault];
        vp.minCollateralPct = minColateral;
    }

    /// @notice Enables/ Disables opening leveraged positions within a vault.
    function toggleVaultLeverage(address vault) external onlyOwner {
        VaultParams storage vp = vaultParams[vault];
        vp.leverageEnabled = !vp.leverageEnabled;
    }

    /// @notice Sets the price feed
    function setPriceFeed(address _priceFeed) external onlyOwner {
        pricefeed = _priceFeed;
    }

    /// @notice Sets the swap router
    function setSwapRouter(address _swapRouter) external onlyOwner {
        swapRouter = _swapRouter;
    }

    /// @notice Sets the minimum borrow amount
    function setMinBorrow(uint256 _minBorrow) external onlyOwner {
        require(_minBorrow > 1e18, "must be at least $1");
        minBorrow = _minBorrow;
    }

    // view functions

    /// @notice checks if a spender is approved or owner
    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view virtual returns (bool) {
        address owner = ERC721.ownerOf(tokenId);
        return (spender == owner || isApprovedForAll(owner, spender) || getApproved(tokenId) == spender);
    }

    /// @notice Gets the tokenIn in a exactOutput swap path
    function _getTokenIn(bytes memory path) internal pure returns (address) {
        while (path.hasMultiplePools()) {
            path.skipToken();
        }

        (, address tokenIn,) = path.decodeFirstPool();
        return tokenIn;
    }

    /// @notice View function to get a position
    function getPosition(uint256 _id) external view returns (Position memory) {
        Position memory pos = positions[_id];
        return pos;
    }
}
