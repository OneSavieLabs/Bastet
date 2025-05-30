// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { FixedPointMathLib } from "solady/src/utils/FixedPointMathLib.sol";
import { WAD } from "../common/LibConstant.sol";

/// @param accountValue based on price
struct MaintenanceMarginProfile {
    uint256 price;
    int256 positionSize;
    int256 openNotional;
    int256 accountValue;
    int256 maintenanceMarginRequirement;
    uint256 liquidationPenaltyRatio;
    uint256 liquidationFeeRatio;
}

struct LiquidationResult {
    int256 liquidatedPositionSizeDelta;
    int256 liquidatedPositionNotionalDelta;
    uint256 penalty;
    uint256 feeToLiquidator;
    uint256 feeToProtocol;
}

// 100 USD in WAD
uint256 constant _MIN_PARTIAL_LIQUIDATE_POSITION_VALUE = 100 * WAD;

library LibLiquidation {
    using SafeCast for uint256;
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for int256;
    using LibLiquidation for MaintenanceMarginProfile;

    function getLiquidationResult(
        MaintenanceMarginProfile memory self,
        uint256 sizeRequestedFromLiquidator
    ) internal view returns (LiquidationResult memory) {
        uint256 liquidatedPositionSizeDeltaAbs = self.getLiquidatedPositionSizeDelta(sizeRequestedFromLiquidator);
        if (liquidatedPositionSizeDeltaAbs == 0) {
            return
                LiquidationResult({
                    liquidatedPositionSizeDelta: 0,
                    liquidatedPositionNotionalDelta: 0,
                    penalty: 0,
                    feeToLiquidator: 0,
                    feeToProtocol: 0
                });
        }
        uint256 liquidatedPositionNotionalDeltaAbs = self.getLiquidatedNotionalDelta(liquidatedPositionSizeDeltaAbs);
        (uint256 feeToLiquidator, uint256 liquidationFeeToProtocol) = self.getPenalty(liquidatedPositionSizeDeltaAbs);

        // if liquidated position was long, liquidation order is short
        bool isLiquidatedPositionLong = self.positionSize > 0;
        int256 liquidatedPositionSizeDelta = isLiquidatedPositionLong
            ? -liquidatedPositionSizeDeltaAbs.toInt256()
            : liquidatedPositionSizeDeltaAbs.toInt256();
        int256 liquidatedPositionNotionalDelta = isLiquidatedPositionLong
            ? liquidatedPositionNotionalDeltaAbs.toInt256()
            : -liquidatedPositionNotionalDeltaAbs.toInt256();

        return
            LiquidationResult({
                liquidatedPositionSizeDelta: liquidatedPositionSizeDelta,
                liquidatedPositionNotionalDelta: liquidatedPositionNotionalDelta,
                penalty: feeToLiquidator + liquidationFeeToProtocol,
                feeToLiquidator: feeToLiquidator,
                feeToProtocol: liquidationFeeToProtocol
            });
    }

    /// @notice penalty = liquidatedPositionNotionalDelta * liquidationPenaltyRatio, shared by liquidator and protocol
    /// liquidationFeeToLiquidator = penalty * liquidation fee ratio. the rest to the protocol
    function getPenalty(
        MaintenanceMarginProfile memory self,
        uint256 liquidatedPositionSizeDelta
    ) internal view returns (uint256, uint256) {
        // reduced percentage = toBeLiquidated / oldSize
        // liquidatedPositionNotionalDelta = oldOpenNotional * percentage = oldOpenNotional * toBeLiquidated / oldSize
        // penalty = liquidatedPositionNotionalDelta * liquidationPenaltyRatio
        uint256 openNotionalAbs = self.openNotional.abs();
        uint256 liquidatedNotionalMulWad = openNotionalAbs * liquidatedPositionSizeDelta;
        uint256 penalty = liquidatedNotionalMulWad.mulWad(self.liquidationPenaltyRatio) / self.positionSize.abs();
        uint256 liquidationFeeToLiquidator = penalty.mulWad(self.liquidationFeeRatio);
        uint256 liquidationFeeToProtocol = penalty - liquidationFeeToLiquidator;
        return (liquidationFeeToLiquidator, liquidationFeeToProtocol);
    }

    /// @notice liquidatable if accountValue < openNotionalAbs * mmRatio
    function getLiquidatablePositionSize(MaintenanceMarginProfile memory self) internal view returns (int256) {
        // No liquidatable position
        if (
            self.accountValue >= self.maintenanceMarginRequirement ||
            self.positionSize == 0 ||
            self.maintenanceMarginRequirement == 0
        ) {
            return 0;
        }

        // Liquidate the entire position if its value is small enough
        // to prevent tiny positions left in the system
        uint256 positionValueAbs = self.positionSize.abs().mulWad(self.price);
        if (positionValueAbs <= _MIN_PARTIAL_LIQUIDATE_POSITION_VALUE) {
            return self.positionSize;
        }

        // Liquidator can only take over half of position if margin ratio is ≥ half of mmRatio.
        // If margin ratio < half of mmRatio, liquidator can take over the entire position.
        if (self.accountValue < self.maintenanceMarginRequirement / 2) {
            return self.positionSize;
        }
        return self.positionSize / 2;
    }

    /// @dev min(given position size, liquidatable position size)
    function getLiquidatedPositionSizeDelta(
        MaintenanceMarginProfile memory self,
        uint256 sizeRequestedFromLiquidator
    ) internal view returns (uint256) {
        // if liquidator request to liquidate more than liquidatable size, liquidate all liquidatable size
        uint256 liquidatableSizeAbs = self.getLiquidatablePositionSize().abs();
        if (sizeRequestedFromLiquidator >= liquidatableSizeAbs) {
            return liquidatableSizeAbs;
        }

        // if liquidatable size is larger than what liquidator requested, liquidate what liquidator requested
        return sizeRequestedFromLiquidator;
    }

    /// @dev Open notional has negative signage vs position size delta
    function getLiquidatedNotionalDelta(
        MaintenanceMarginProfile memory self,
        uint256 liquidatedPositionSizeDeltaAbs
    ) internal pure returns (uint256) {
        return liquidatedPositionSizeDeltaAbs.mulWad(self.price);
    }
}
