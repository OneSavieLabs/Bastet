// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    VaultAccount,
    VaultConfig,
    VaultState,
    VaultAccountHealthFactors,
    PrimeRate,
    CashGroupParameters,
    MarketParameters,
    Token
} from "../../global/Types.sol";
import {Constants} from "../../global/Constants.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";

import {TokenHandler} from "../balances/TokenHandler.sol";
import {CashGroup} from "../markets/CashGroup.sol";
import {Market} from "../markets/Market.sol";
import {PrimeRateLib} from "../pCash/PrimeRateLib.sol";
import {AssetHandler} from "../valuation/AssetHandler.sol";

import {VaultSecondaryBorrow} from "./VaultSecondaryBorrow.sol";
import {VaultConfiguration} from "./VaultConfiguration.sol";

import {IStrategyVault} from "../../../interfaces/notional/IStrategyVault.sol";
import {IVaultAccountHealth} from "../../../interfaces/notional/IVaultController.sol";

/// @notice Leveraged vaults have three components to the valuation of a position:
///     - VaultShareValue: the value of a single vault share which can be transferred between
///       leveraged vault accounts.
///
///     - DebtOutstanding: the value of debts held by the account, discounted to present value
///       when fCash discounting is enabled.
///
///         debtOutstanding = presentValue(primaryDebt) + convertToPrimary(presentValue(secondaryDebt))
///
///     - AccountCashHeld: the value of cash held by the account against debt. Cash is only deposited to
///       the account during liquidation and must be cleared on any subsequent non-liquidation transaction.
///
///         accountCashHeld = primaryCash + convertToPrimary(secondaryCash)
library VaultValuation {
    using SafeInt256 for int256;
    using SafeUint256 for uint256;
    using VaultConfiguration for VaultConfig;
    using CashGroup for CashGroupParameters;
    using TokenHandler for Token;
    using Market for MarketParameters;
    using PrimeRateLib for PrimeRate;

    /// @notice Returns the value in underlying of the primary borrow currency portion of vault shares.
    function getPrimaryUnderlyingValueOfShare(
        VaultState memory vaultState,
        VaultConfig memory vaultConfig,
        address account,
        uint256 vaultShares
    ) internal view returns (int256) {
        if (vaultShares == 0) return 0;

        Token memory token = TokenHandler.getUnderlyingToken(vaultConfig.borrowCurrencyId);
        return token.convertToInternal(
            IStrategyVault(vaultConfig.vault).convertStrategyToUnderlying(account, vaultShares, vaultState.maturity)
        );
    }

    function getLiquidateCashDiscountFactor(
        PrimeRate memory primeRate,
        uint16 currencyId,
        uint256 maturity
    ) internal view returns (int256) {
        CashGroupParameters memory cashGroup = CashGroup.buildCashGroup(currencyId, primeRate);
        uint256 oracleRate = cashGroup.calculateOracleRate(maturity, block.timestamp);
        uint256 buffer = cashGroup.getLiquidationDebtBuffer();
        return AssetHandler.getDiscountFactor(
            maturity.sub(block.timestamp),
            oracleRate < buffer ? 0 : oracleRate.sub(buffer)
        );
    }

    function getPresentValue(
        PrimeRate memory primeRate,
        uint16 currencyId,
        uint256 maturity,
        int256 debtUnderlying,
        bool enableDiscount
    ) internal view returns (int256) {
        if (maturity <= block.timestamp) {
            // Matured vaults will have a present value of the settled value of the fCash along
            // with accrued prime cash debt. The value returned by this method is already in prime cash.
            // Prime cash will never trip this if condition since PRIME_CASH_VAULT_MATURITY is in the
            // distant future
            return primeRate.convertToUnderlying(
                primeRate.convertSettledfCashView(currencyId, maturity, debtUnderlying, block.timestamp)
            );
        } else if (enableDiscount && maturity != Constants.PRIME_CASH_VAULT_MATURITY) {
            CashGroupParameters memory cashGroup = CashGroup.buildCashGroup(currencyId, primeRate);
            uint256 oracleRate = cashGroup.calculateOracleRate(maturity, block.timestamp);
            // Use the risk adjusted present fCash value so that local currency liquidation has room to
            // pay the liquidator.
            debtUnderlying = AssetHandler.getRiskAdjustedPresentfCashValue(
                cashGroup, debtUnderlying, maturity, block.timestamp, oracleRate
            );
        }

        // If fCash discount is disabled, fCash is valued at its notional value. Prime cash is always
        // valued at its current value.
        return debtUnderlying;
    }

    function getCollateralRatioFactorsStateful(
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        address account,
        uint256 vaultShares,
        int256 debtUnderlying
    ) internal returns (int256 collateralRatio, int256 vaultShareValue) {
        vaultShareValue = getPrimaryUnderlyingValueOfShare(vaultState, vaultConfig, account, vaultShares);

        int256 debtOutstanding = getPresentValue(
            vaultConfig.primeRate,
            vaultConfig.borrowCurrencyId,
            vaultState.maturity,
            debtUnderlying,
            vaultConfig.getFlag(VaultConfiguration.ENABLE_FCASH_DISCOUNT)
        );

        if (vaultConfig.hasSecondaryBorrows()) {
            PrimeRate[2] memory primeRates = VaultSecondaryBorrow.getSecondaryPrimeRateStateful(vaultConfig);
            (int256 secondaryDebtInPrimary, /* */, /* */, /* */) =
                VaultSecondaryBorrow.getSecondaryBorrowCollateralFactors(vaultConfig, primeRates, vaultState, account);
            debtOutstanding = debtOutstanding.add(secondaryDebtInPrimary);
        }

        // All inputs into this method are underlying and in primary currency denomination
        collateralRatio = calculateCollateralRatio(vaultShareValue, debtOutstanding);
    }

    /// @notice Calculates the collateral ratio of an account:
    ///     vaultShareValue + (debtOutstanding + accountCashHeld)
    ///     ----------------------------------------------------
    ///            -1 * (debtOutstanding + accountCashHeld)
    /// @param vaultShareValue vault share value in primary underlying denomination
    /// @param netDebtOutstanding debt outstanding in primary currency underlying denomination
    /// @return collateralRatio for an account, expressed in 1e9 "RATE_PRECISION"
    function calculateCollateralRatio(
        int256 vaultShareValue,
        int256 netDebtOutstanding
    ) internal pure returns (int256 collateralRatio) {
        // netAssetValue includes the value held in vaultShares net off against the outstanding debt.
        // netAssetValue can be either positive or negative here. If it is positive (normal condition)
        // then the account has more value than debt, if it is negative then the account is insolvent
        // (it cannot repay its debt if we sold all of its vault shares).
        int256 netAssetValue = vaultShareValue.add(netDebtOutstanding);

        // We calculate the collateral ratio (netAssetValue to debt ratio):
        //  if netAssetValue > 0 and netDebtOutstanding < 0: collateralRatio > 0, closer to zero means more risk
        //  if netAssetValue < 0 and netDebtOutstanding < 0: collateralRatio < 0, the account is insolvent
        //  if debtOutstanding >= 0: collateralRatio is infinity, there is no risk at all (no debt left)
        if (netDebtOutstanding >= 0)  {
            // When there is no debt outstanding then we use a maximal collateral ratio to represent "infinity"
            collateralRatio = type(int256).max;
        } else {
            // Negate debt outstanding in the denominator so collateral ratio is positive
            collateralRatio = netAssetValue.divInRatePrecision(netDebtOutstanding.neg());
        }
    }

    /// @notice Calculates account health factors for liquidation.
    function calculateAccountHealthFactors(
        VaultConfig memory vaultConfig,
        VaultAccount memory vaultAccount,
        VaultState memory vaultState,
        PrimeRate[2] memory primeRates
    ) internal view returns (
        VaultAccountHealthFactors memory h,
        VaultSecondaryBorrow.SecondaryExchangeRates memory er
    ) {

        h.vaultShareValueUnderlying = getPrimaryUnderlyingValueOfShare(
            vaultState, vaultConfig, vaultAccount.account, vaultAccount.vaultShares
        );

        h.debtOutstanding[0] = getPresentValue(
            vaultConfig.primeRate,
            vaultConfig.borrowCurrencyId,
            vaultState.maturity,
            vaultAccount.accountDebtUnderlying,
            vaultConfig.getFlag(VaultConfiguration.ENABLE_FCASH_DISCOUNT)
        // During liquidation, it is possible that the vault account has a temp cash balance due to
        // a previous liquidation.
        ).add(vaultConfig.primeRate.convertToUnderlying(vaultAccount.tempCashBalance));
        h.totalDebtOutstandingInPrimary = h.debtOutstanding[0];

        if (vaultConfig.hasSecondaryBorrows()) {
            int256 secondaryDebtInPrimary;
            (secondaryDebtInPrimary, er, h.debtOutstanding[1], h.debtOutstanding[2]) = 
                VaultSecondaryBorrow.getSecondaryBorrowCollateralFactors(
                    vaultConfig, primeRates, vaultState, vaultAccount.account
                );

            h.totalDebtOutstandingInPrimary = h.totalDebtOutstandingInPrimary.add(secondaryDebtInPrimary);
        }

        h.collateralRatio = calculateCollateralRatio(h.vaultShareValueUnderlying, h.totalDebtOutstandingInPrimary);
    }

    function getLiquidationFactors(
        VaultConfig memory vaultConfig,
        VaultAccountHealthFactors memory h,
        VaultSecondaryBorrow.SecondaryExchangeRates memory er,
        uint256 currencyIndex,
        int256 vaultShares,
        int256 depositUnderlyingInternal
    ) internal pure returns (int256, uint256) {
        // Short circuit all calculations if there is no vault share value
        if (h.vaultShareValueUnderlying <= 0) return (0, 0);

        int256 minBorrowSize;
        if (currencyIndex == 0) {
            minBorrowSize = vaultConfig.minAccountBorrowSize;
        } else {
            // Return zero if the secondary borrow currency is not defined
            if (vaultConfig.secondaryBorrowCurrencies[currencyIndex - 1] == 0) return (0, 0);
            // Otherwise set the min borrow size appropriately
            minBorrowSize = vaultConfig.minAccountSecondaryBorrow[currencyIndex - 1];
        }


        // If currencyIndex == 0 then the exchange rate is the unit rate, this will be
        // the case the vast majority of the time.
        int256 exchangeRate;
        // If there are no secondary borrows, the exchange rate may be unset, resulting in divide by
        // zero errors so it is set to 1 here.
        (exchangeRate, er.rateDecimals) = er.rateDecimals == 0 ? (1, 1) : (er.rateDecimals, er.rateDecimals);
        if (currencyIndex == 1) exchangeRate = er.exchangeRateOne;
        else if (currencyIndex == 2) exchangeRate = er.exchangeRateTwo;

        int256 maxLiquidatorDepositLocal = _calculateDeleverageAmount(
            vaultConfig,
            h.vaultShareValueUnderlying,
            h.totalDebtOutstandingInPrimary.neg(),
            h.debtOutstanding[currencyIndex].neg(),
            minBorrowSize,
            exchangeRate,
            er.rateDecimals
        );

        // NOTE: deposit amount is always positive in this method
        if (depositUnderlyingInternal < maxLiquidatorDepositLocal) {
            // If liquidating past the debt outstanding above the min borrow, then the entire
            // debt outstanding must be liquidated.

            // (debtOutstanding - depositAmountUnderlying) is the post liquidation debt. As an
            // edge condition, when debt outstanding is discounted to present value, the account
            // may be liquidated to zero while their debt outstanding is still greater than the
            // min borrow size (which is normally enforced in notional terms -- i.e. non present
            // value). Resolving this would require additional complexity for not much gain. An
            // account within 20% of the minBorrowSize in a vault that has fCash discounting enabled
            // may experience a full liquidation as a result.
            require(
                h.debtOutstanding[currencyIndex].sub(depositUnderlyingInternal) < minBorrowSize,
                "Must Liquidate All Debt"
            );
        } else {
            // If the deposit amount is greater than maxLiquidatorDeposit then limit it to the max
            // amount here.
            depositUnderlyingInternal = maxLiquidatorDepositLocal;
        }

        // Convert to primary denomination, same as vault shares
        int256 depositAmountPrimary = depositUnderlyingInternal.mul(er.rateDecimals).div(exchangeRate);
        uint256 vaultSharesToLiquidator = _calculateVaultSharesToLiquidator(
            vaultShares,
            vaultConfig.liquidationRate,
            h.vaultShareValueUnderlying,
            depositAmountPrimary
        );

        return (depositUnderlyingInternal, vaultSharesToLiquidator);
    }

    /// @notice Calculates the amount a liquidator can deposit in underlying terms to deleverage an account.
    /// @param vaultConfig the vault configuration
    /// @param vaultShareValueUnderlying value of the vault account's vault shares
    /// @param totalDebtOutstanding total debt outstanding in the account
    /// @param localDebtOutstanding value of the debt in the currency being liquidated
    /// @param minAccountBorrowSizeLocal minimum amount the account must borrow in the local currency
    /// @param exchangeRate exchange rate between the local currency and primary
    /// @param rateDecimals precision of the exchange rate between local currency and primary
    /// @return maxLiquidatorDepositLocal the maximum a liquidator can deposit in local underlying internal denomination
    function _calculateDeleverageAmount(
        VaultConfig memory vaultConfig,
        // NOTE: vaultShareValueUnderlying is never zero or negative in this method due to the first if
        // statement inside getLiquidationFactors
        int256 vaultShareValueUnderlying,
        int256 totalDebtOutstanding,
        int256 localDebtOutstanding,
        int256 minAccountBorrowSizeLocal,
        int256 exchangeRate,
        int256 rateDecimals
    ) private pure returns (int256 maxLiquidatorDepositLocal) {
        // In the base case, the liquidator can deleverage an account up to maxDeleverageCollateralRatio, this
        // assures that a liquidator cannot over-purchase assets on an account.
        int256 maxCollateralRatioPlusOne = vaultConfig.maxDeleverageCollateralRatio.add(Constants.RATE_PRECISION);

        // The post liquidation collateral ratio is calculated as:
        //                          (shareValue - (debtOutstanding - deposit * (1 - liquidationRate)))
        //   postLiquidationRatio = ----------------------------------------------------------------
        //                                          (debtOutstanding - deposit)
        //
        //   if we rearrange terms to put the deposit on one side we get:
        //
        //              (postLiquidationRatio + 1) * debtOutstanding - shareValue
        //   deposit =  ---------------------------------------------------------- 
        //                  (postLiquidationRatio + 1) - liquidationRate

        int256 maxLiquidatorDepositPrimary = (
            totalDebtOutstanding.mulInRatePrecision(maxCollateralRatioPlusOne).sub(vaultShareValueUnderlying)
        // Both denominators are in 1e9 precision
        ).divInRatePrecision(maxCollateralRatioPlusOne.sub(vaultConfig.liquidationRate));

        maxLiquidatorDepositLocal = maxLiquidatorDepositPrimary.mul(exchangeRate).div(rateDecimals);
        int256 postLiquidationDebtRemaining = localDebtOutstanding.sub(maxLiquidatorDepositLocal);

        // Cap the liquidator's deposit to the local debt outstanding under the two conditions:
        //  - Liquidator cannot repay more than the debt outstanding
        //  - If an account's (debtOutstanding - maxLiquidatorDeposit) < minAccountBorrowSize it may not be
        //    profitable to liquidate a second time due to gas costs. If this occurs the liquidator must
        //    liquidate the account such that it has no fCash debt.
        if (
            localDebtOutstanding < maxLiquidatorDepositLocal ||
            postLiquidationDebtRemaining < minAccountBorrowSizeLocal
        ) {
            maxLiquidatorDepositLocal = localDebtOutstanding;
            maxLiquidatorDepositPrimary = localDebtOutstanding.mul(rateDecimals).div(exchangeRate);
        }

        // Check that the maxLiquidatorDepositLocal does not exceed the total vault shares owned by
        // the account:
        //                               vaultShares * (deposit * liquidationRate)
        //    vaultSharesToLiquidator =  -----------------------------------------
        //                                   vaultShareValue * RATE_PRECISION
        //
        // If (deposit * liquidationRate) / vaultShareValue > RATE_PRECISION then the account may be
        // insolvent (or unable to reach the maxDeleverageCollateralRatio) and we are over liquidating.
        //
        // In this case the liquidator's max deposit is:
        //      (deposit * liquidationRate) / vaultShareValue == RATE_PRECISION, therefore:
        //      deposit = (RATE_PRECISION * vaultShareValue / liquidationRate)
        int256 depositRatio = maxLiquidatorDepositPrimary.mul(vaultConfig.liquidationRate).div(vaultShareValueUnderlying);

        // Use equal to so we catch potential off by one issues, the deposit amount calculated inside the if statement
        // below will round the maxLiquidatorDepositPrimeCash down
        if (depositRatio >= Constants.RATE_PRECISION) {
            maxLiquidatorDepositPrimary = vaultShareValueUnderlying.divInRatePrecision(vaultConfig.liquidationRate);
            maxLiquidatorDepositLocal = maxLiquidatorDepositPrimary.mul(exchangeRate).div(rateDecimals);
        }
    }

    /// @notice Returns how many vault shares the liquidator will receive given their deposit
    /// @param vaultShares vault shares held on the account
    /// @param liquidationRate the discount rate on the liquidation
    /// @param vaultShareValueUnderlying the value in primary underlying of all of the account's vault shares
    /// @param liquidatorDepositPrimaryUnderlying the amount of deposit in primary underlying
    /// @return vaultSharesToLiquidator the number of vault shares to transfer to the liquidator
    function _calculateVaultSharesToLiquidator(
        int256 vaultShares,
        int256 liquidationRate,
        int256 vaultShareValueUnderlying,
        int256 liquidatorDepositPrimaryUnderlying
    ) private pure returns (uint256 vaultSharesToLiquidator) {
        // Calculates the following:
        //                liquidationRate * liquidatorDeposit
        // vaultShares * -----------------------------------
        //                RATE_PRECISION * vaultShareValue
        vaultSharesToLiquidator = vaultShares
            .mul(liquidationRate)
            .mul(liquidatorDepositPrimaryUnderlying)
            .div(vaultShareValueUnderlying)
            .div(Constants.RATE_PRECISION)
            .toUint();
    }
}
