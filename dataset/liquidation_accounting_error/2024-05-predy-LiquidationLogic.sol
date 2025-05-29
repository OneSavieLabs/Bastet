// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {SafeTransferLib} from "@solmate/src/utils/SafeTransferLib.sol";
import {ERC20} from "@solmate/src/tokens/ERC20.sol";
import {IPredyPool} from "../../interfaces/IPredyPool.sol";
import {IHooks} from "../../interfaces/IHooks.sol";
import {ISettlement} from "../../interfaces/ISettlement.sol";
import {ApplyInterestLib} from "../ApplyInterestLib.sol";
import {Constants} from "../Constants.sol";
import {Perp} from "../Perp.sol";
import {PerpFee} from "../PerpFee.sol";
import {Trade} from "../Trade.sol";
import {Math} from "../math/Math.sol";
import {DataType} from "../DataType.sol";
import {GlobalDataLibrary} from "../../types/GlobalData.sol";
import {PositionCalculator} from "../PositionCalculator.sol";
import {ScaledAsset} from "../ScaledAsset.sol";
import {SlippageLib} from "../SlippageLib.sol";

library LiquidationLogic {
    using Math for int256;
    using GlobalDataLibrary for GlobalDataLibrary.GlobalData;
    using SafeTransferLib for ERC20;

    // 3% scaled by 1e8
    uint256 constant _MAX_ACCEPTABLE_SQRT_PRICE_RANGE = 101488915;

    event PositionLiquidated(
        uint256 indexed vaultId,
        uint256 pairId,
        int256 tradeAmount,
        int256 tradeSqrtAmount,
        IPredyPool.Payoff payoff,
        int256 fee,
        uint256 marginAmount
    );

    function liquidate(
        uint256 vaultId,
        uint256 closeRatio,
        GlobalDataLibrary.GlobalData storage globalData,
        bytes memory settlementData
    ) external returns (IPredyPool.TradeResult memory tradeResult) {
        require(closeRatio > 0 && closeRatio <= 1e18, "ICR");
        DataType.Vault storage vault = globalData.vaults[vaultId];
        DataType.PairStatus storage pairStatus = globalData.pairs[vault.openPosition.pairId];

        // update interest growth
        ApplyInterestLib.applyInterestForToken(globalData.pairs, vault.openPosition.pairId);

        // update rebalance interest growth
        Perp.updateRebalanceInterestGrowth(pairStatus, pairStatus.sqrtAssetStatus);

        // Checks the vault is danger
        (uint256 sqrtOraclePrice, uint256 slippageTolerance) =
            checkVaultIsDanger(pairStatus, vault, globalData.rebalanceFeeGrowthCache);

        IPredyPool.TradeParams memory tradeParams = IPredyPool.TradeParams(
            vault.openPosition.pairId,
            vaultId,
            -vault.openPosition.perp.amount * int256(closeRatio) / 1e18,
            -vault.openPosition.sqrtPerp.amount * int256(closeRatio) / 1e18,
            ""
        );

        tradeResult = Trade.trade(globalData, tradeParams, settlementData);

        vault.margin += tradeResult.fee + tradeResult.payoff.perpPayoff + tradeResult.payoff.sqrtPayoff;

        tradeResult.sqrtTwap = sqrtOraclePrice;

        bool hasPosition;

        (tradeResult.minMargin,, hasPosition,) =
            PositionCalculator.calculateMinMargin(pairStatus, vault, DataType.FeeAmount(0, 0));

        // Check if the price is within the slippage tolerance range to ensure that the price does not become
        // excessively favorable to the liquidator.
        SlippageLib.checkPrice(
            sqrtOraclePrice,
            tradeResult,
            slippageTolerance,
            tradeParams.tradeAmountSqrt == 0 ? 0 : _MAX_ACCEPTABLE_SQRT_PRICE_RANGE
        );

        uint256 sentMarginAmount = 0;

        if (!hasPosition) {
            int256 remainingMargin = vault.margin;

            if (remainingMargin > 0) {
                if (vault.recipient != address(0)) {
                    // Send the remaining margin to the recipient.
                    vault.margin = 0;

                    sentMarginAmount = uint256(remainingMargin);

                    ERC20(pairStatus.quotePool.token).safeTransfer(vault.recipient, sentMarginAmount);
                }
            } else if (remainingMargin < 0) {
                vault.margin = 0;

                // To prevent the liquidator from unfairly profiting through arbitrage trades in the AMM and passing losses onto the protocol,
                // any losses that cannot be covered by the vault must be compensated by the liquidator
                ERC20(pairStatus.quotePool.token).safeTransferFrom(msg.sender, address(this), uint256(-remainingMargin));
            }
        }

        emit PositionLiquidated(
            tradeParams.vaultId,
            tradeParams.pairId,
            tradeParams.tradeAmount,
            tradeParams.tradeAmountSqrt,
            tradeResult.payoff,
            tradeResult.fee,
            sentMarginAmount
        );
    }

    /**
     * @notice Check vault safety and get slippage tolerance
     * @param pairStatus The pair status
     * @param vault The vault object
     * @param rebalanceFeeGrowthCache rebalance fee growth
     * @return sqrtOraclePrice The square root of oracle price used for value calculation
     * @return slippageTolerance slippage tolerance calculated by minMargin and vault value
     */
    function checkVaultIsDanger(
        DataType.PairStatus memory pairStatus,
        DataType.Vault memory vault,
        mapping(uint256 => DataType.RebalanceFeeGrowthCache) storage rebalanceFeeGrowthCache
    ) internal view returns (uint256 sqrtOraclePrice, uint256 slippageTolerance) {
        bool isLiquidatable;
        int256 minMargin;
        int256 vaultValue;

        DataType.FeeAmount memory FeeAmount =
            PerpFee.computeUserFee(pairStatus, rebalanceFeeGrowthCache, vault.openPosition);

        (isLiquidatable, minMargin, vaultValue, sqrtOraclePrice) =
            PositionCalculator.isLiquidatable(pairStatus, vault, FeeAmount);

        if (!isLiquidatable) {
            revert IPredyPool.VaultIsNotDanger(vaultValue, minMargin);
        }

        slippageTolerance = calculateSlippageTolerance(minMargin, vaultValue, pairStatus.riskParams);
    }

    /**
     * @notice Calculates slippage tolerance based on minMargin and vaultValue.
     * the smaller the vault value, the larger the slippage tolerance becomes like Dutch auction.
     * @param minMargin minMargin value
     * @param vaultValue vault value
     * @param riskParams risk parameters
     * @return slippageTolerance slippage tolerance calculated by minMargin and vault value
     */
    function calculateSlippageTolerance(int256 minMargin, int256 vaultValue, Perp.AssetRiskParams memory riskParams)
        internal
        pure
        returns (uint256)
    {
        if (vaultValue <= 0 || minMargin == 0) {
            return riskParams.maxSlippage;
        }

        uint256 ratio = uint256(vaultValue * 1e4 / minMargin);

        if (ratio > 1e4) {
            return riskParams.minSlippage;
        }

        return (riskParams.maxSlippage - ratio * (riskParams.maxSlippage - riskParams.minSlippage) / 1e4);
    }
}
