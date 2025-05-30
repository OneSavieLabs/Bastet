// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Math} from "@src/libraries/Math.sol";

import {PERCENT} from "@src/libraries/Math.sol";

import {CreditPosition, DebtPosition, LoanLibrary, LoanStatus} from "@src/libraries/LoanLibrary.sol";
import {BorrowOffer, OfferLibrary} from "@src/libraries/OfferLibrary.sol";
import {VariablePoolBorrowRateParams} from "@src/libraries/YieldCurveLibrary.sol";

import {State} from "@src/SizeStorage.sol";

import {Liquidate, LiquidateParams} from "@src/libraries/actions/Liquidate.sol";

import {Errors} from "@src/libraries/Errors.sol";
import {Events} from "@src/libraries/Events.sol";

struct LiquidateWithReplacementParams {
    // The debt position ID to liquidate
    uint256 debtPositionId;
    // The borrower
    address borrower;
    // The minimum profit in collateral tokens expected by the liquidator
    uint256 minimumCollateralProfit;
    // The deadline for the transaction
    uint256 deadline;
    // The minimum APR for the loan
    uint256 minAPR;
}

/// @title LiquidateWithReplacement
/// @custom:security-contact security@size.credit
/// @author Size (https://size.credit/)
/// @notice Contains the logic for liquidating a debt position with a replacement borrower
library LiquidateWithReplacement {
    using LoanLibrary for CreditPosition;
    using OfferLibrary for BorrowOffer;

    using LoanLibrary for State;
    using Liquidate for State;
    using LoanLibrary for DebtPosition;

    /// @notice Validates the input parameters for liquidating a debt position with a replacement borrower
    /// @param state The state
    /// @param params The input parameters for liquidating a debt position with a replacement borrower
    function validateLiquidateWithReplacement(State storage state, LiquidateWithReplacementParams calldata params)
        external
        view
    {
        DebtPosition storage debtPosition = state.getDebtPosition(params.debtPositionId);
        BorrowOffer storage borrowOffer = state.data.users[params.borrower].borrowOffer;

        // validate liquidate
        state.validateLiquidate(
            LiquidateParams({
                debtPositionId: params.debtPositionId,
                minimumCollateralProfit: params.minimumCollateralProfit
            })
        );

        // validate debtPositionId
        if (state.getLoanStatus(params.debtPositionId) != LoanStatus.ACTIVE) {
            revert Errors.LOAN_NOT_ACTIVE(params.debtPositionId);
        }
        uint256 tenor = debtPosition.dueDate - block.timestamp;
        if (tenor < state.riskConfig.minTenor || tenor > state.riskConfig.maxTenor) {
            revert Errors.TENOR_OUT_OF_RANGE(tenor, state.riskConfig.minTenor, state.riskConfig.maxTenor);
        }

        // validate borrower
        if (borrowOffer.isNull()) {
            revert Errors.INVALID_BORROW_OFFER(params.borrower);
        }

        // validate deadline
        if (params.deadline < block.timestamp) {
            revert Errors.PAST_DEADLINE(params.deadline);
        }

        // validate minAPR
        uint256 apr = borrowOffer.getAPRByTenor(
            VariablePoolBorrowRateParams({
                variablePoolBorrowRate: state.oracle.variablePoolBorrowRate,
                variablePoolBorrowRateUpdatedAt: state.oracle.variablePoolBorrowRateUpdatedAt,
                variablePoolBorrowRateStaleRateInterval: state.oracle.variablePoolBorrowRateStaleRateInterval
            }),
            tenor
        );
        if (apr < params.minAPR) {
            revert Errors.APR_LOWER_THAN_MIN_APR(apr, params.minAPR);
        }
    }

    /// @notice Validates the minimum profit in collateral tokens expected by the liquidator
    /// @param state The state
    /// @param params The input parameters for liquidating a debt position with a replacement borrower
    /// @param liquidatorProfitCollateralToken The profit in collateral tokens expected by the liquidator
    function validateMinimumCollateralProfit(
        State storage state,
        LiquidateWithReplacementParams calldata params,
        uint256 liquidatorProfitCollateralToken
    ) external pure {
        Liquidate.validateMinimumCollateralProfit(
            state,
            LiquidateParams({
                debtPositionId: params.debtPositionId,
                minimumCollateralProfit: params.minimumCollateralProfit
            }),
            liquidatorProfitCollateralToken
        );
    }

    /// @notice Executes the liquidation of a debt position with a replacement borrower
    /// @param state The state
    /// @param params The input parameters for liquidating a debt position with a replacement borrower
    /// @return issuanceValue The issuance value
    /// @return liquidatorProfitCollateralToken The profit in collateral tokens expected by the liquidator
    /// @return liquidatorProfitBorrowToken The profit in borrow tokens expected by the liquidator
    function executeLiquidateWithReplacement(State storage state, LiquidateWithReplacementParams calldata params)
        external
        returns (uint256 issuanceValue, uint256 liquidatorProfitCollateralToken, uint256 liquidatorProfitBorrowToken)
    {
        emit Events.LiquidateWithReplacement(params.debtPositionId, params.borrower, params.minimumCollateralProfit);

        DebtPosition storage debtPosition = state.getDebtPosition(params.debtPositionId);
        DebtPosition memory debtPositionCopy = debtPosition;
        BorrowOffer storage borrowOffer = state.data.users[params.borrower].borrowOffer;
        uint256 tenor = debtPositionCopy.dueDate - block.timestamp;

        liquidatorProfitCollateralToken = state.executeLiquidate(
            LiquidateParams({
                debtPositionId: params.debtPositionId,
                minimumCollateralProfit: params.minimumCollateralProfit
            })
        );

        uint256 ratePerTenor = borrowOffer.getRatePerTenor(
            VariablePoolBorrowRateParams({
                variablePoolBorrowRate: state.oracle.variablePoolBorrowRate,
                variablePoolBorrowRateUpdatedAt: state.oracle.variablePoolBorrowRateUpdatedAt,
                variablePoolBorrowRateStaleRateInterval: state.oracle.variablePoolBorrowRateStaleRateInterval
            }),
            tenor
        );
        issuanceValue = Math.mulDivDown(debtPositionCopy.futureValue, PERCENT, PERCENT + ratePerTenor);
        liquidatorProfitBorrowToken = debtPositionCopy.futureValue - issuanceValue;

        debtPosition.borrower = params.borrower;
        debtPosition.futureValue = debtPositionCopy.futureValue;
        debtPosition.liquidityIndexAtRepayment = 0;

        emit Events.UpdateDebtPosition(
            params.debtPositionId,
            debtPosition.borrower,
            debtPosition.futureValue,
            debtPosition.liquidityIndexAtRepayment
        );

        state.data.debtToken.mint(params.borrower, debtPosition.futureValue);
        state.data.borrowAToken.transferFrom(address(this), params.borrower, issuanceValue);
        state.data.borrowAToken.transferFrom(address(this), state.feeConfig.feeRecipient, liquidatorProfitBorrowToken);
    }
}
