// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "./BaseOrderUtils.sol";
import "../swap/SwapUtils.sol";
import "../position/DecreasePositionUtils.sol";
import "../order/OrderStoreUtils.sol";
import "../utils/ErrorUtils.sol";

// @title DecreaseOrderUtils
// @dev Library for functions to help with processing a decrease order
library DecreaseOrderUtils {
    using Position for Position.Props;
    using Order for Order.Props;
    using Array for uint256[];

    // @dev process a decrease order
    // @param params BaseOrderUtils.ExecuteOrderParams
    function processOrder(BaseOrderUtils.ExecuteOrderParams memory params) external {
        Order.Props memory order = params.order;
        MarketUtils.validateEnabledMarket(params.contracts.dataStore, params.market);
        MarketUtils.validatePositionMarket(params.market);

        bytes32 positionKey = PositionUtils.getPositionKey(order.account(), order.market(), order.initialCollateralToken(), order.isLong());
        Position.Props memory position = PositionStoreUtils.get(params.contracts.dataStore, positionKey);
        PositionUtils.validateNonEmptyPosition(position);

        validateOracleBlockNumbers(
            params.minOracleBlockNumbers,
            params.maxOracleBlockNumbers,
            order.orderType(),
            order.updatedAtBlock(),
            position.increasedAtBlock(),
            position.decreasedAtBlock()
        );

        DecreasePositionUtils.DecreasePositionResult memory result = DecreasePositionUtils.decreasePosition(
            PositionUtils.UpdatePositionParams(
                params.contracts,
                params.market,
                order,
                params.key,
                position,
                positionKey
            )
        );

        OrderStoreUtils.remove(params.contracts.dataStore, params.key, order.account());

        // if the pnlToken and the collateralToken are different
        // and if a swap fails or no swap was requested
        // then it is possible to receive two separate tokens from decreasing
        // the position
        // transfer the two tokens to the user in this case and skip processing
        // the swapPath
        if (result.secondaryOutputAmount > 0) {
            MarketToken(payable(order.market())).transferOut(
                result.outputToken,
                order.receiver(),
                result.outputAmount,
                order.shouldUnwrapNativeToken()
            );

            MarketToken(payable(order.market())).transferOut(
                result.secondaryOutputToken,
                order.receiver(),
                result.secondaryOutputAmount,
                order.shouldUnwrapNativeToken()
            );

            return;
        }

        if (order.swapPath().length == 0) {
            MarketToken(payable(order.market())).transferOut(
                result.outputToken,
                order.receiver(),
                result.outputAmount,
                order.shouldUnwrapNativeToken()
            );
        } else {
            try params.contracts.swapHandler.swap(
                SwapUtils.SwapParams(
                    params.contracts.dataStore,
                    params.contracts.eventEmitter,
                    params.contracts.oracle,
                    Bank(payable(order.market())),
                    result.outputToken,
                    result.outputAmount,
                    params.swapPathMarkets,
                    order.minOutputAmount(),
                    order.receiver(),
                    order.shouldUnwrapNativeToken()
                )
            ) returns (address /* tokenOut */, uint256 /* swapOutputAmount */) {
            } catch Error(string memory reason) {
                _handleSwapError(
                    order,
                    result,
                    reason,
                    ""
                );
            } catch (bytes memory reasonBytes) {
                (string memory reason, /* bool hasRevertMessage */) = ErrorUtils.getRevertMessage(reasonBytes);
                _handleSwapError(
                    order,
                    result,
                    reason,
                    reasonBytes
                );
            }
        }
    }

    // @dev validate the oracle block numbers used for the prices in the oracle
    // @param oracleBlockNumbers the oracle block numbers
    // @param orderType the order type
    // @param orderUpdatedAtBlock the block at which the order was last updated
    // @param positionIncreasedAtBlock the block at which the position was last increased
    // @param positionDecreasedAtBlock the block at which the position was last decreased
    function validateOracleBlockNumbers(
        uint256[] memory minOracleBlockNumbers,
        uint256[] memory maxOracleBlockNumbers,
        Order.OrderType orderType,
        uint256 orderUpdatedAtBlock,
        uint256 positionIncreasedAtBlock,
        uint256 positionDecreasedAtBlock
    ) internal pure {
        if (orderType == Order.OrderType.MarketDecrease) {
            OracleUtils.validateBlockNumberWithinRange(
                minOracleBlockNumbers,
                maxOracleBlockNumbers,
                orderUpdatedAtBlock
            );
            return;
        }

        if (
            orderType == Order.OrderType.LimitDecrease ||
            orderType == Order.OrderType.StopLossDecrease
        ) {
            uint256 latestUpdatedAtBlock = orderUpdatedAtBlock > positionIncreasedAtBlock ? orderUpdatedAtBlock : positionIncreasedAtBlock;
            if (!minOracleBlockNumbers.areGreaterThan(latestUpdatedAtBlock)) {
                OracleUtils.revertOracleBlockNumbersAreSmallerThanRequired(minOracleBlockNumbers, latestUpdatedAtBlock);
            }
            return;
        }

        if (orderType == Order.OrderType.Liquidation) {
            uint256 latestUpdatedAtBlock = positionIncreasedAtBlock > positionDecreasedAtBlock ? positionIncreasedAtBlock : positionDecreasedAtBlock;

            if (!minOracleBlockNumbers.areGreaterThan(latestUpdatedAtBlock)) {
                OracleUtils.revertOracleBlockNumbersAreSmallerThanRequired(minOracleBlockNumbers, latestUpdatedAtBlock);
            }
            return;
        }

        BaseOrderUtils.revertUnsupportedOrderType();
    }

    function _handleSwapError(
        Order.Props memory order,
        DecreasePositionUtils.DecreasePositionResult memory result,
        string memory reason,
        bytes memory reasonBytes
    ) internal {
        emit SwapUtils.SwapReverted(reason, reasonBytes);

        MarketToken(payable(order.market())).transferOut(
            result.outputToken,
            order.receiver(),
            result.outputAmount,
            order.shouldUnwrapNativeToken()
        );
    }
}