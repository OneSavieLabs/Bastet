// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "./FixedPoint.sol";

library Position {
    using FixedPoint for uint256;
    uint256 internal constant ONE = 1e18;

    // TODO: pack better
    struct Info {
        uint120 notional; // initial notional = collateral * leverage
        uint120 debt; // debt
        bool isLong; // whether long or short
        bool liquidated; // whether has been liquidated
        uint256 entryPrice; // price received at entry
        uint256 oiShares; // shares of aggregate open interest on side
    }

    /*///////////////////////////////////////////////////////////////
                        POSITIONS MAPPING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Retrieves a position from positions mapping
    function get(
        mapping(bytes32 => Info) storage self,
        address owner,
        uint256 id
    ) internal view returns (Info storage position_) {
        position_ = self[keccak256(abi.encodePacked(owner, id))];
    }

    /// @notice Stores a position in positions mapping
    function set(
        mapping(bytes32 => Info) storage self,
        address owner,
        uint256 id,
        Info memory position
    ) internal {
        self[keccak256(abi.encodePacked(owner, id))] = position;
    }

    /*///////////////////////////////////////////////////////////////
                    POSITION CAST GETTER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Computes the position's initial notional cast to uint256
    function _notional(Info memory self) private pure returns (uint256) {
        return uint256(self.notional);
    }

    /// @notice Computes the position's initial open interest cast to uint256
    function _oiShares(Info memory self) private pure returns (uint256) {
        return uint256(self.oiShares);
    }

    /// @notice Computes the position's debt cast to uint256
    function _debt(Info memory self) private pure returns (uint256) {
        return uint256(self.debt);
    }

    /// @notice Whether the position exists
    /// @dev Is false if position has been liquidated or has zero oi
    function exists(Info memory self) internal pure returns (bool exists_) {
        return (!self.liquidated && self.notional > 0);
    }

    /*///////////////////////////////////////////////////////////////
                POSITION FRACTIONAL GETTER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Computes the initial notional of position when built
    /// @dev use mulUp to avoid rounding leftovers on unwind
    function notionalInitial(Info memory self, uint256 fraction) internal pure returns (uint256) {
        return _notional(self).mulUp(fraction);
    }

    /// @notice Computes the initial open interest of position when built
    /// @dev use mulUp to avoid rounding leftovers on unwind
    function oiInitial(Info memory self, uint256 fraction) internal pure returns (uint256) {
        return _oiShares(self).mulUp(fraction);
    }

    /// @notice Computes the current shares of open interest position holds
    /// @notice on pos.isLong side of the market
    /// @dev use mulUp to avoid rounding leftovers on unwind
    function oiSharesCurrent(Info memory self, uint256 fraction) internal pure returns (uint256) {
        return _oiShares(self).mulUp(fraction);
    }

    /// @notice Computes the current debt position holds
    /// @dev use mulUp to avoid rounding leftovers on unwind
    function debtCurrent(Info memory self, uint256 fraction) internal pure returns (uint256) {
        return _debt(self).mulUp(fraction);
    }

    /// @notice Computes the current open interest of a position accounting for
    /// @notice potential funding payments between long/short sides
    /// @dev returns zero when oiShares = oiTotalOnSide = oiTotalSharesOnSide = 0 to avoid
    /// @dev div by zero errors
    /// @dev use mulUp, divUp to avoid rounding leftovers on unwind
    function oiCurrent(
        Info memory self,
        uint256 fraction,
        uint256 oiTotalOnSide,
        uint256 oiTotalSharesOnSide
    ) internal pure returns (uint256) {
        uint256 posOiShares = oiSharesCurrent(self, fraction);
        if (posOiShares == 0 || oiTotalOnSide == 0) return 0;
        return posOiShares.mulUp(oiTotalOnSide).divUp(oiTotalSharesOnSide);
    }

    /*///////////////////////////////////////////////////////////////
                        POSITION CALC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Computes the position's cost cast to uint256
    /// WARNING: be careful modifying notional and debt on unwind
    function cost(Info memory self, uint256 fraction) internal pure returns (uint256) {
        uint256 posNotionalInitial = notionalInitial(self, fraction);
        uint256 posDebt = debtCurrent(self, fraction);

        // should always be > 0 but use Math.min to be safe w reverts
        uint256 posCost = posNotionalInitial;
        posCost -= Math.min(posCost, posDebt);
        return posCost;
    }

    /// @notice Computes the value of a position
    /// @dev Floors to zero, so won't properly compute if self is underwater
    // TODO: test
    function value(
        Info memory self,
        uint256 fraction,
        uint256 oiTotalOnSide,
        uint256 oiTotalSharesOnSide,
        uint256 currentPrice,
        uint256 capPayoff
    ) internal pure returns (uint256 val_) {
        uint256 posOiInitial = oiInitial(self, fraction);
        uint256 posNotionalInitial = notionalInitial(self, fraction);
        uint256 posDebt = debtCurrent(self, fraction);

        uint256 posOiCurrent = oiCurrent(self, fraction, oiTotalOnSide, oiTotalSharesOnSide);
        uint256 entryPrice = self.entryPrice;

        // NOTE: PnL = +/- oiCurrent * [currentPrice - entryPrice]; ... (w/o capPayoff)
        // NOTE: fundingPayments = notionalInitial * ( oiCurrent / oiInitial - 1 )
        // NOTE: value = collateralInitial + PnL + fundingPayments
        // NOTE:       = notionalInitial - debt + PnL + fundingPayments
        if (self.isLong) {
            // val = notionalInitial * oiCurrent / oiInitial
            //       + oiCurrent * min[currentPrice, entryPrice * (1 + capPayoff)]
            //       - oiCurrent * entryPrice - debt
            val_ =
                posNotionalInitial.mulUp(posOiCurrent).divUp(posOiInitial) +
                Math.min(
                    posOiCurrent.mulUp(currentPrice),
                    posOiCurrent.mulUp(entryPrice).mulUp(ONE + capPayoff)
                );
            // floor to 0
            val_ -= Math.min(val_, posDebt + posOiCurrent.mulUp(entryPrice));
        } else {
            // NOTE: capPayoff >= 1, so no need to include w short
            // val = notionalInitial * oiCurrent / oiInitial + oiCurrent * entryPrice
            //       - oiCurrent * currentPrice - debt
            val_ =
                posNotionalInitial.mulUp(posOiCurrent).divUp(posOiInitial) +
                posOiCurrent.mulUp(entryPrice);
            // floor to 0
            val_ -= Math.min(val_, posDebt + posOiCurrent.mulUp(currentPrice));
        }
    }

    /// @notice Computes the current notional of a position including PnL
    /// @dev Floors to debt if value <= 0
    function notionalWithPnl(
        Info memory self,
        uint256 fraction,
        uint256 oiTotalOnSide,
        uint256 oiTotalSharesOnSide,
        uint256 currentPrice,
        uint256 capPayoff
    ) internal pure returns (uint256 notionalWithPnl_) {
        uint256 posValue = value(
            self,
            fraction,
            oiTotalOnSide,
            oiTotalSharesOnSide,
            currentPrice,
            capPayoff
        );
        uint256 posDebt = debtCurrent(self, fraction);
        notionalWithPnl_ = posValue + posDebt;
    }

    /// @notice Computes the trading fees to be imposed on a position for build/unwind
    function tradingFee(
        Info memory self,
        uint256 fraction,
        uint256 oiTotalOnSide,
        uint256 oiTotalSharesOnSide,
        uint256 currentPrice,
        uint256 capPayoff,
        uint256 tradingFeeRate
    ) internal pure returns (uint256 tradingFee_) {
        uint256 posNotional = notionalWithPnl(
            self,
            fraction,
            oiTotalOnSide,
            oiTotalSharesOnSide,
            currentPrice,
            capPayoff
        );
        tradingFee_ = posNotional.mulUp(tradingFeeRate);
    }

    /// @notice Whether a position can be liquidated
    /// @dev is true when value < maintenance margin
    function liquidatable(
        Info memory self,
        uint256 oiTotalOnSide,
        uint256 oiTotalSharesOnSide,
        uint256 currentPrice,
        uint256 capPayoff,
        uint256 maintenanceMarginFraction
    ) internal pure returns (bool can_) {
        uint256 fraction = ONE;
        uint256 posNotionalInitial = notionalInitial(self, fraction);

        if (self.liquidated || posNotionalInitial == 0) {
            // already been liquidated
            return false;
        }

        uint256 val = value(
            self,
            fraction,
            oiTotalOnSide,
            oiTotalSharesOnSide,
            currentPrice,
            capPayoff
        );
        uint256 maintenanceMargin = posNotionalInitial.mulUp(maintenanceMarginFraction);
        can_ = val < maintenanceMargin;
    }

    /// @notice Computes the liquidation price of a position
    /// @dev price when value = maintenance margin
    function liquidationPrice(
        Info memory self,
        uint256 oiTotalOnSide,
        uint256 oiTotalSharesOnSide,
        uint256 maintenanceMarginFraction
    ) internal pure returns (uint256 liqPrice_) {
        uint256 fraction = ONE;

        uint256 posOiInitial = oiInitial(self, fraction);
        uint256 posNotionalInitial = notionalInitial(self, fraction);
        uint256 posDebt = debtCurrent(self, fraction);

        uint256 posOiCurrent = oiCurrent(self, fraction, oiTotalOnSide, oiTotalSharesOnSide);
        uint256 entryPrice = self.entryPrice;

        if (self.liquidated || posNotionalInitial == 0 || posOiCurrent == 0) {
            // return 0 if already liquidated or no oi left in position
            return 0;
        }

        if (self.isLong) {
            // liqPrice = (debt + mm * notionalInitial) / oiCurrent
            //            + entryPrice - notionalInitial / oiInitial
            liqPrice_ =
                posNotionalInitial.mulDown(maintenanceMarginFraction).add(posDebt).divDown(
                    posOiCurrent
                ) +
                entryPrice -
                posNotionalInitial.divUp(posOiInitial);
        } else {
            // liqPrice = entryPrice + notionalInitial / oiInitial
            //            - (debt + mm * notionalInitial) / oiCurrent
            liqPrice_ = self.entryPrice + posNotionalInitial.divUp(posOiInitial);
            // floor to zero
            liqPrice_ -= Math.min(
                liqPrice_,
                posNotionalInitial.mulUp(maintenanceMarginFraction).add(posDebt).divUp(
                    posOiCurrent
                )
            );
        }
    }
}