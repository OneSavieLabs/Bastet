// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "../storage/InsuranceFund.sol";
import "./MarketProcess.sol";
import "./LpPoolProcess.sol";
import "./FeeProcess.sol";
import "./AccountProcess.sol";
import "./CancelOrderProcess.sol";
import "./FeeQueryProcess.sol";
import "./PositionMarginProcess.sol";

library DecreasePositionProcess {
    using SafeMath for uint256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using SignedSafeMath for int256;
    using Math for uint256;
    using Position for Position.Props;
    using Order for Order.Props;
    using Account for Account.Props;
    using AccountProcess for Account.Props;
    using Market for Market.Props;

    struct DecreasePositionParams {
        uint256 requestId;
        bytes32 symbol;
        bool isLiquidation;
        bool isCrossMargin;
        address marginToken;
        uint256 decreaseQty;
        uint256 executePrice;
    }

    struct DecreasePositionCache {
        address stakeToken;
        Position.Props position;
        uint256 marginTokenPrice;
        int256 executePrice;
        int256 recordPnlToken;
        int256 settledMargin;
        uint256 decreaseMargin;
        int256 decreaseIntQty;
        int256 positionIntQty;
        uint256 decreaseMarginInUsd;
        uint256 decreaseMarginInUsdFromBalance;
        uint256 settledBorrowingFee;
        uint256 settledBorrowingFeeInUsd;
        int256 settledFundingFee;
        int256 settledFundingFeeInUsd;
        int256 settledFee;
        uint256 unHoldPoolAmount;
        uint256 closeFee;
        uint256 closeFeeInUsd;
        int256 realizedPnl;
        int256 poolPnlToken;
        bool isLiquidation;
    }

    function decreasePosition(Position.Props storage position, DecreasePositionParams calldata params) external {
        int256 totalPnlInUsd = PositionQueryProcess.getPositionUnPnl(position, params.executePrice.toInt256(), false);
        Symbol.Props memory symbolProps = Symbol.load(params.symbol);
        AppConfig.SymbolConfig memory symbolConfig = AppConfig.getSymbolConfig(params.symbol);
        FeeProcess.updateBorrowingFee(position, symbolProps.stakeToken);
        FeeProcess.updateFundingFee(position);
        DecreasePositionCache memory cache = _updateDecreasePosition(
            position,
            params.decreaseQty,
            totalPnlInUsd,
            params.executePrice.toInt256(),
            symbolConfig.closeFeeRate,
            params.isLiquidation,
            params.isCrossMargin
        );
        if (cache.settledMargin < 0 && !cache.isLiquidation && !position.isCrossMargin) {
            revert Errors.PositionShouldBeLiquidation();
        }
        cache.stakeToken = symbolProps.stakeToken;
        cache.isLiquidation = params.isLiquidation;

        Account.Props storage accountProps = Account.load(position.account);
        if (params.decreaseQty == position.qty) {
            accountProps.delPosition(
                Position.getPositionKey(position.account, position.symbol, position.marginToken, position.isCrossMargin)
            );
            position.reset();
        } else {
            position.qty -= params.decreaseQty;
            position.initialMargin -= cache.decreaseMargin;
            position.initialMarginInUsd -= cache.decreaseMarginInUsd;
            position.initialMarginInUsdFromBalance -= cache.decreaseMarginInUsdFromBalance;
            position.holdPoolAmount -= cache.unHoldPoolAmount;
            position.realizedPnl += cache.realizedPnl;
            position.positionFee.realizedBorrowingFee -= cache.settledBorrowingFee;
            position.positionFee.realizedBorrowingFeeInUsd -= cache.settledBorrowingFeeInUsd;
            position.positionFee.realizedFundingFee -= cache.settledFundingFee;
            position.positionFee.realizedFundingFeeInUsd -= cache.settledFundingFeeInUsd;
            position.positionFee.closeFeeInUsd -= cache.closeFeeInUsd;
            position.lastUpdateTime = ChainUtils.currentTimestamp();
        }

        FeeProcess.chargeTradingFee(
            cache.closeFee,
            symbolProps.code,
            cache.isLiquidation ? FeeProcess.FEE_LIQUIDATION : FeeProcess.FEE_CLOSE_POSITION,
            cache.position.marginToken,
            cache.position
        );

        FeeProcess.chargeBorrowingFee(
            position.isCrossMargin,
            cache.settledBorrowingFee,
            symbolProps.stakeToken,
            cache.position.marginToken,
            position.account,
            cache.isLiquidation ? FeeProcess.FEE_LIQUIDATION : FeeProcess.FEE_BORROWING
        );

        if (cache.position.isCrossMargin) {
            uint256 addLiability = _settleCrossAccount(params.requestId, accountProps, position, cache);
            accountProps.repayLiability(cache.position.marginToken);
            LpPoolProcess.updatePnlAndUnHoldPoolAmount(
                symbolProps.stakeToken,
                cache.position.marginToken,
                cache.unHoldPoolAmount,
                cache.poolPnlToken,
                addLiability
            );
        } else {
            _settleIsolateAccount(accountProps, cache);
            LpPoolProcess.updatePnlAndUnHoldPoolAmount(
                symbolProps.stakeToken,
                cache.position.marginToken,
                cache.unHoldPoolAmount,
                cache.poolPnlToken,
                0
            );
        }

        // update total borrowing
        MarketProcess.updateTotalBorrowingFee(
            symbolProps.stakeToken,
            cache.position.isLong,
            cache.position.marginToken,
            cache.settledBorrowingFee.toInt256(),
            -cache.settledBorrowingFee.toInt256()
        );

        // update funding fee
        MarketProcess.updateMarketFundingFee(
            symbolProps.code,
            -cache.settledFundingFee,
            cache.position.isLong,
            !position.isCrossMargin,
            cache.position.marginToken
        );

        // update & verify OI
        MarketProcess.updateMarketOI(
            MarketProcess.UpdateOIParams(
                false,
                symbolProps.code,
                cache.position.marginToken,
                params.decreaseQty,
                0,
                cache.position.isLong
            )
        );

        // cancel stop orders
        CancelOrderProcess.cancelStopOrders(
            cache.position.account,
            symbolProps.code,
            cache.position.marginToken,
            cache.position.isCrossMargin,
            CancelOrderProcess.CANCEL_ORDER_POSITION_CLOSE,
            params.requestId
        );

        // update insuranceFund
        if (cache.isLiquidation) {
            _addFunds(cache);
        }

        position.emitPositionUpdateEvent(
            params.requestId,
            cache.isLiquidation ? Position.PositionUpdateFrom.LIQUIDATION : Position.PositionUpdateFrom.ORDER_DECREASE,
            Position.SettleData(
                params.executePrice,
                0,
                cache.marginTokenPrice,
                cache.settledMargin,
                cache.settledBorrowingFee,
                cache.settledBorrowingFeeInUsd,
                cache.settledFundingFee,
                cache.settledFundingFeeInUsd,
                cache.unHoldPoolAmount,
                cache.closeFee,
                cache.closeFeeInUsd,
                cache.realizedPnl,
                cache.poolPnlToken
            )
        );
    }

    function _updateDecreasePosition(
        Position.Props storage position,
        uint256 decreaseQty,
        int256 pnlInUsd,
        int256 executePrice,
        uint256 closeFeeRate,
        bool isLiquidation,
        bool isCrossMargin
    ) internal view returns (DecreasePositionCache memory cache) {
        cache.position = position;
        cache.executePrice = executePrice;
        int256 tokenPrice = OracleProcess.getLatestUsdPrice(position.marginToken, false);
        cache.marginTokenPrice = tokenPrice.toUint256();
        uint8 tokenDecimals = TokenUtils.decimals(position.marginToken);
        if (position.qty == decreaseQty) {
            cache.decreaseMargin = cache.position.initialMargin;
            cache.decreaseMarginInUsd = cache.position.initialMarginInUsd;
            cache.unHoldPoolAmount = cache.position.holdPoolAmount;
            (cache.settledBorrowingFee, cache.settledBorrowingFeeInUsd) = FeeQueryProcess.calcBorrowingFee(
                decreaseQty,
                position
            );
            cache.settledFundingFee = cache.position.positionFee.realizedFundingFee;
            cache.settledFundingFeeInUsd = cache.position.positionFee.realizedFundingFeeInUsd;

            cache.closeFeeInUsd = cache.position.positionFee.closeFeeInUsd;
            cache.closeFee = FeeQueryProcess.calcCloseFee(tokenDecimals, cache.closeFeeInUsd, tokenPrice.toUint256());
            cache.settledFee =
                cache.settledBorrowingFee.toInt256() +
                cache.settledFundingFee +
                cache.closeFee.toInt256();

            if (isLiquidation) {
                cache.settledMargin = isCrossMargin
                    ? CalUtils.usdToTokenInt(
                        cache.position.initialMarginInUsd.toInt256() -
                            _getPosFee(cache) +
                            pnlInUsd -
                            PositionQueryProcess.getPositionMM(cache.position).toInt256(),
                        TokenUtils.decimals(cache.position.marginToken),
                        tokenPrice
                    )
                    : int256(0);
                cache.recordPnlToken = cache.settledMargin - cache.decreaseMargin.toInt256();
                cache.poolPnlToken =
                    cache.decreaseMargin.toInt256() -
                    CalUtils.usdToTokenInt(
                        cache.position.initialMarginInUsd.toInt256() + pnlInUsd,
                        TokenUtils.decimals(cache.position.marginToken),
                        tokenPrice
                    );
            } else {
                cache.settledMargin = CalUtils.usdToTokenInt(
                    cache.position.initialMarginInUsd.toInt256() - _getPosFee(cache) + pnlInUsd,
                    TokenUtils.decimals(cache.position.marginToken),
                    tokenPrice
                );
                cache.recordPnlToken = cache.settledMargin - cache.decreaseMargin.toInt256();
                cache.poolPnlToken =
                    cache.decreaseMargin.toInt256() -
                    CalUtils.usdToTokenInt(
                        cache.position.initialMarginInUsd.toInt256() + pnlInUsd,
                        TokenUtils.decimals(cache.position.marginToken),
                        tokenPrice
                    );
            }
            cache.realizedPnl = CalUtils.tokenToUsdInt(
                cache.recordPnlToken,
                TokenUtils.decimals(cache.position.marginToken),
                tokenPrice
            );
        } else {
            cache.decreaseMargin = cache.position.initialMargin.mul(decreaseQty).div(cache.position.qty);
            cache.unHoldPoolAmount = cache.position.holdPoolAmount.mul(decreaseQty).div(cache.position.qty);
            cache.closeFeeInUsd = CalUtils.mulRate(decreaseQty, closeFeeRate);
            (cache.settledBorrowingFee, cache.settledBorrowingFeeInUsd) = FeeQueryProcess.calcBorrowingFee(
                decreaseQty,
                position
            );
            cache.decreaseIntQty = decreaseQty.toInt256();
            cache.positionIntQty = cache.position.qty.toInt256();
            cache.settledFundingFee = cache.position.positionFee.realizedFundingFee.mul(cache.decreaseIntQty).div(
                cache.positionIntQty
            );
            cache.settledFundingFeeInUsd = cache
                .position
                .positionFee
                .realizedFundingFeeInUsd
                .mul(cache.decreaseIntQty)
                .div(cache.positionIntQty);

            if (cache.closeFeeInUsd > cache.position.positionFee.closeFeeInUsd) {
                cache.closeFeeInUsd = cache.position.positionFee.closeFeeInUsd;
            }
            cache.closeFee = FeeQueryProcess.calcCloseFee(tokenDecimals, cache.closeFeeInUsd, tokenPrice.toUint256());
            cache.settledFee =
                cache.settledBorrowingFee.toInt256() +
                cache.settledFundingFee +
                cache.closeFee.toInt256();
            cache.settledMargin = CalUtils.usdToTokenInt(
                (cache.position.initialMarginInUsd.toInt256() - _getPosFee(cache) + pnlInUsd)
                    .mul(cache.decreaseIntQty)
                    .div(cache.positionIntQty),
                TokenUtils.decimals(cache.position.marginToken),
                tokenPrice
            );
            cache.recordPnlToken = cache.settledMargin - cache.decreaseMargin.toInt256();
            cache.poolPnlToken =
                cache.decreaseMargin.toInt256() -
                CalUtils.usdToTokenInt(
                    (cache.position.initialMarginInUsd.toInt256() + pnlInUsd).mul(cache.decreaseIntQty).div(
                        cache.positionIntQty
                    ),
                    TokenUtils.decimals(cache.position.marginToken),
                    tokenPrice
                );
            cache.decreaseMarginInUsd = cache.position.initialMarginInUsd.mul(decreaseQty).div(position.qty);
            cache.realizedPnl = CalUtils.tokenToUsdInt(
                cache.recordPnlToken,
                TokenUtils.decimals(cache.position.marginToken),
                tokenPrice
            );
        }

        cache.decreaseMarginInUsdFromBalance = (cache.decreaseMarginInUsd + position.initialMarginInUsdFromBalance >
            position.initialMarginInUsd)
            ? cache.decreaseMarginInUsd + position.initialMarginInUsdFromBalance - position.initialMarginInUsd
            : 0;

        return cache;
    }

    function _settleCrossAccount(
        uint256 requestId,
        Account.Props storage accountProps,
        Position.Props storage position,
        DecreasePositionCache memory cache
    ) internal returns (uint256 addLiability) {
        if (cache.settledFee > 0) {
            accountProps.subTokenWithLiability(
                cache.position.marginToken,
                cache.settledFee.toUint256(),
                Account.UpdateSource.SETTLE_FEE
            );
        } else {
            accountProps.addToken(
                cache.position.marginToken,
                (-cache.settledFee).toUint256(),
                Account.UpdateSource.SETTLE_FEE
            );
        }
        accountProps.unUseToken(
            cache.position.marginToken,
            cache.decreaseMargin,
            Account.UpdateSource.DECREASE_POSITION
        );
        address portfolioVault = IVault(address(this)).getPortfolioVaultAddress();
        if (cache.recordPnlToken >= 0) {
            accountProps.addToken(
                cache.position.marginToken,
                (cache.recordPnlToken + cache.settledFee).toUint256(),
                Account.UpdateSource.SETTLE_PNL
            );
            VaultProcess.transferOut(
                cache.position.isLong ? cache.stakeToken : CommonData.getStakeUsdToken(),
                cache.position.marginToken,
                portfolioVault,
                cache.recordPnlToken.toUint256(),
                true
            );
            if (!cache.position.isLong) {
                VaultProcess.transferOut(
                    CommonData.getStakeUsdToken(),
                    cache.position.marginToken,
                    cache.stakeToken,
                    cache.closeFee,
                    true
                );
            }
        } else if (cache.recordPnlToken < 0) {
            addLiability = accountProps.subTokenWithLiability(
                cache.position.marginToken,
                (-cache.recordPnlToken).toUint256()
            );
            VaultProcess.transferOut(
                portfolioVault,
                cache.position.marginToken,
                cache.stakeToken,
                (-cache.recordPnlToken).toUint256() - addLiability,
                true
            );
        }
        if (!cache.isLiquidation) {
            int256 changeToken = (
                cache.decreaseMarginInUsdFromBalance.mul(cache.position.initialMargin).div(
                    cache.position.initialMarginInUsd
                )
            ).toInt256() +
                cache.settledMargin -
                cache.decreaseMargin.toInt256();
            PositionMarginProcess.updateAllPositionFromBalanceMargin(
                requestId,
                accountProps.owner,
                cache.position.marginToken,
                changeToken,
                position.key
            );
        }
    }

    function _settleIsolateAccount(Account.Props storage accountProps, DecreasePositionCache memory cache) internal {
        if (cache.isLiquidation) {
            return;
        }
        if (cache.recordPnlToken < 0 || (cache.recordPnlToken >= 0 && cache.position.isLong)) {
            VaultProcess.transferOut(
                cache.stakeToken,
                cache.position.marginToken,
                accountProps.owner,
                cache.settledMargin.toUint256(),
                true
            );
        } else {
            VaultProcess.transferOut(
                CommonData.getStakeUsdToken(),
                cache.position.marginToken,
                cache.stakeToken,
                cache.recordPnlToken.toUint256() + cache.closeFee,
                true
            );
            VaultProcess.transferOut(
                cache.stakeToken,
                cache.position.marginToken,
                accountProps.owner,
                cache.settledMargin.toUint256(),
                true
            );
        }
    }

    function _addFunds(DecreasePositionCache memory cache) internal {
        if (cache.position.isCrossMargin) {
            InsuranceFund.addFunds(
                cache.stakeToken,
                cache.position.marginToken,
                CalUtils.usdToToken(
                    PositionQueryProcess.getPositionMM(cache.position),
                    TokenUtils.decimals(cache.position.marginToken),
                    cache.marginTokenPrice
                )
            );
            return;
        }
        uint256 addFunds;
        if (cache.settledFee >= 0) {
            addFunds = cache.decreaseMargin > (cache.settledFee + cache.poolPnlToken).toUint256()
                ? cache.decreaseMargin - (cache.settledFee + cache.poolPnlToken).toUint256()
                : 0;
        } else {
            addFunds = cache.decreaseMargin + (-cache.settledFee).toUint256() - cache.poolPnlToken.toUint256();
        }
        InsuranceFund.addFunds(cache.stakeToken, cache.position.marginToken, addFunds);
    }

    function _getPosFee(DecreasePositionCache memory cache) internal pure returns (int256) {
        return
            cache.closeFeeInUsd.toInt256() + cache.settledBorrowingFeeInUsd.toInt256() + cache.settledFundingFeeInUsd;
    }
}
