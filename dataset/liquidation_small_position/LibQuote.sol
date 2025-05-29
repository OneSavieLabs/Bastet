// SPDX-License-Identifier: SYMM-Core-Business-Source-License-1.1
// This contract is licensed under the SYMM Core Business Source License 1.1
// Copyright (c) 2023 Symmetry Labs AG
// For more information, see https://docs.symm.io/legal-disclaimer/license
pragma solidity >=0.8.18;

import "./LibLockedValues.sol";
import "../storages/QuoteStorage.sol";
import "../storages/AccountStorage.sol";
import "../storages/GlobalAppStorage.sol";
import "../storages/SymbolStorage.sol";
import "../storages/MAStorage.sol";

library LibQuote {
    using LockedValuesOps for LockedValues;

    function getAmountToLockOfQuote(Quote storage quote) internal view returns (uint256) {
        return quote.lockedValues.total();
    }

    function quoteOpenAmount(Quote storage quote) internal view returns (uint256) {
        return quote.quantity - quote.closedAmount;
    }

    function getIndexOfItem(
        uint256[] storage array_,
        uint256 item
    ) internal view returns (uint256) {
        for (uint256 index = 0; index < array_.length; index++) {
            if (array_[index] == item) return index;
        }
        return type(uint256).max;
    }

    function removeFromArray(uint256[] storage array_, uint256 item) internal {
        uint256 index = getIndexOfItem(array_, item);
        require(index != type(uint256).max, "LibQuote: Item not Found");
        array_[index] = array_[array_.length - 1];
        array_.pop();
    }

    function removeFromPartyAPendingQuotes(Quote storage quote) internal {
        removeFromArray(QuoteStorage.layout().partyAPendingQuotes[quote.partyA], quote.id);
    }

    function removeFromPartyBPendingQuotes(Quote storage quote) internal {
        removeFromArray(
            QuoteStorage.layout().partyBPendingQuotes[quote.partyB][quote.partyA],
            quote.id
        );
    }

    function removeFromPendingQuotes(Quote storage quote) internal {
        removeFromPartyAPendingQuotes(quote);
        removeFromPartyBPendingQuotes(quote);
    }

    function addToOpenPositions(uint256 quoteId) internal {
        QuoteStorage.Layout storage quoteLayout = QuoteStorage.layout();
        Quote storage quote = quoteLayout.quotes[quoteId];

        quoteLayout.partyAOpenPositions[quote.partyA].push(quote.id);
        quoteLayout.partyBOpenPositions[quote.partyB][quote.partyA].push(quote.id);

        quoteLayout.partyAPositionsIndex[quote.id] = quoteLayout.partyAPositionsCount[quote.partyA];
        quoteLayout.partyBPositionsIndex[quote.id] = quoteLayout.partyBPositionsCount[quote.partyB][
            quote.partyA
        ];

        quoteLayout.partyAPositionsCount[quote.partyA] += 1;
        quoteLayout.partyBPositionsCount[quote.partyB][quote.partyA] += 1;
    }

    function removeFromOpenPositions(uint256 quoteId) internal {
        QuoteStorage.Layout storage quoteLayout = QuoteStorage.layout();
        Quote storage quote = quoteLayout.quotes[quoteId];
        uint256 indexOfPartyAPosition = quoteLayout.partyAPositionsIndex[quote.id];
        uint256 indexOfPartyBPosition = quoteLayout.partyBPositionsIndex[quote.id];
        uint256 lastOpenPositionIndex = quoteLayout.partyAPositionsCount[quote.partyA] - 1;
        quoteLayout.partyAOpenPositions[quote.partyA][indexOfPartyAPosition] = quoteLayout
            .partyAOpenPositions[quote.partyA][lastOpenPositionIndex];
        quoteLayout.partyAPositionsIndex[
            quoteLayout.partyAOpenPositions[quote.partyA][lastOpenPositionIndex]
        ] = indexOfPartyAPosition;
        quoteLayout.partyAOpenPositions[quote.partyA].pop();

        lastOpenPositionIndex = quoteLayout.partyBPositionsCount[quote.partyB][quote.partyA] - 1;
        quoteLayout.partyBOpenPositions[quote.partyB][quote.partyA][
            indexOfPartyBPosition
        ] = quoteLayout.partyBOpenPositions[quote.partyB][quote.partyA][lastOpenPositionIndex];
        quoteLayout.partyBPositionsIndex[
            quoteLayout.partyBOpenPositions[quote.partyB][quote.partyA][lastOpenPositionIndex]
        ] = indexOfPartyBPosition;
        quoteLayout.partyBOpenPositions[quote.partyB][quote.partyA].pop();

        quoteLayout.partyAPositionsIndex[quote.id] = 0;
        quoteLayout.partyBPositionsIndex[quote.id] = 0;
    }

    function getValueOfQuoteForPartyA(
        uint256 currentPrice,
        uint256 filledAmount,
        Quote storage quote
    ) internal view returns (bool hasMadeProfit, uint256 pnl) {
        if (currentPrice > quote.openedPrice) {
            if (quote.positionType == PositionType.LONG) {
                hasMadeProfit = true;
            } else {
                hasMadeProfit = false;
            }
            pnl = ((currentPrice - quote.openedPrice) * filledAmount) / 1e18;
        } else {
            if (quote.positionType == PositionType.LONG) {
                hasMadeProfit = false;
            } else {
                hasMadeProfit = true;
            }
            pnl = ((quote.openedPrice - currentPrice) * filledAmount) / 1e18;
        }
    }

    function getTradingFee(uint256 quoteId) internal view returns (uint256 fee) {
        QuoteStorage.Layout storage quoteLayout = QuoteStorage.layout();
        Quote storage quote = quoteLayout.quotes[quoteId];
        Symbol storage symbol = SymbolStorage.layout().symbols[quote.symbolId];
        if (quote.orderType == OrderType.LIMIT) {
            fee =
                (LibQuote.quoteOpenAmount(quote) * quote.requestedOpenPrice * symbol.tradingFee) /
                1e36;
        } else {
            fee = (LibQuote.quoteOpenAmount(quote) * quote.marketPrice * symbol.tradingFee) / 1e36;
        }
    }

    function returnTradingFee(uint256 quoteId) internal {
        AccountStorage.Layout storage accountLayout = AccountStorage.layout();
        uint256 tradingFee = LibQuote.getTradingFee(quoteId);
        accountLayout.allocatedBalances[QuoteStorage.layout().quotes[quoteId].partyA] += tradingFee;
        accountLayout.balances[GlobalAppStorage.layout().feeCollector] -= tradingFee;
    }

    function receiveTradingFee(uint256 quoteId) internal {
        AccountStorage.Layout storage accountLayout = AccountStorage.layout();
        uint256 tradingFee = LibQuote.getTradingFee(quoteId);
        accountLayout.allocatedBalances[QuoteStorage.layout().quotes[quoteId].partyA] -= tradingFee;
        accountLayout.balances[GlobalAppStorage.layout().feeCollector] += tradingFee;
    }

    function closeQuote(Quote storage quote, uint256 filledAmount, uint256 closedPrice) internal {
        QuoteStorage.Layout storage quoteLayout = QuoteStorage.layout();
        AccountStorage.Layout storage accountLayout = AccountStorage.layout();

        quote.modifyTimestamp = block.timestamp;

        LockedValues memory lockedValues = LockedValues(
            quote.lockedValues.cva -
                ((quote.lockedValues.cva * filledAmount) / (LibQuote.quoteOpenAmount(quote))),
            quote.lockedValues.mm -
                ((quote.lockedValues.mm * filledAmount) / (LibQuote.quoteOpenAmount(quote))),
            quote.lockedValues.lf -
                ((quote.lockedValues.lf * filledAmount) / (LibQuote.quoteOpenAmount(quote)))
        );
        accountLayout.lockedBalances[quote.partyA].subQuote(quote).add(lockedValues);
        accountLayout.partyBLockedBalances[quote.partyB][quote.partyA].subQuote(quote).add(
            lockedValues
        );
        quote.lockedValues = lockedValues;

        (bool hasMadeProfit, uint256 pnl) = LibQuote.getValueOfQuoteForPartyA(
            closedPrice,
            filledAmount,
            quote
        );
        if (hasMadeProfit) {
            accountLayout.allocatedBalances[quote.partyA] += pnl;
            accountLayout.partyBAllocatedBalances[quote.partyB][quote.partyA] -= pnl;
        } else {
            accountLayout.allocatedBalances[quote.partyA] -= pnl;
            accountLayout.partyBAllocatedBalances[quote.partyB][quote.partyA] += pnl;
        }

        quote.avgClosedPrice =
            (quote.avgClosedPrice * quote.closedAmount + filledAmount * closedPrice) /
            (quote.closedAmount + filledAmount);

        quote.closedAmount += filledAmount;
        quote.quantityToClose -= filledAmount;

        if (quote.closedAmount == quote.quantity) {
            quote.quoteStatus = QuoteStatus.CLOSED;
            quote.requestedClosePrice = 0;
            removeFromOpenPositions(quote.id);
            quoteLayout.partyAPositionsCount[quote.partyA] -= 1;
            quoteLayout.partyBPositionsCount[quote.partyB][quote.partyA] -= 1;
        } else if (
            quote.quoteStatus == QuoteStatus.CANCEL_CLOSE_PENDING || quote.quantityToClose == 0
        ) {
            quote.quoteStatus = QuoteStatus.OPENED;
            quote.requestedClosePrice = 0;
            quote.quantityToClose = 0; // for CANCEL_CLOSE_PENDING status
        } else {
            require(
                quote.lockedValues.total() >=
                    SymbolStorage.layout().symbols[quote.symbolId].minAcceptableQuoteValue,
                "LibQuote: Remaining quote value is low"
            );
        }
    }

    function expireQuote(uint256 quoteId) internal returns (QuoteStatus result) {
        QuoteStorage.Layout storage quoteLayout = QuoteStorage.layout();
        AccountStorage.Layout storage accountLayout = AccountStorage.layout();

        Quote storage quote = quoteLayout.quotes[quoteId];
        require(block.timestamp > quote.deadline, "LibQuote: Quote isn't expired");
        require(
            quote.quoteStatus == QuoteStatus.PENDING ||
                quote.quoteStatus == QuoteStatus.CANCEL_PENDING ||
                quote.quoteStatus == QuoteStatus.LOCKED ||
                quote.quoteStatus == QuoteStatus.CLOSE_PENDING ||
                quote.quoteStatus == QuoteStatus.CANCEL_CLOSE_PENDING,
            "LibQuote: Invalid state"
        );
        require(
            !MAStorage.layout().liquidationStatus[quote.partyA],
            "LibQuote: PartyA isn't solvent"
        );
        require(
            !MAStorage.layout().partyBLiquidationStatus[quote.partyB][quote.partyA],
            "LibQuote: PartyB isn't solvent"
        );
        if (
            quote.quoteStatus == QuoteStatus.PENDING ||
            quote.quoteStatus == QuoteStatus.LOCKED ||
            quote.quoteStatus == QuoteStatus.CANCEL_PENDING
        ) {
            quote.modifyTimestamp = block.timestamp;
            accountLayout.partyANonces[quote.partyA] += 1;
            accountLayout.pendingLockedBalances[quote.partyA].subQuote(quote);
            // send trading Fee back to partyA
            LibQuote.returnTradingFee(quoteId);
            removeFromPartyAPendingQuotes(quote);
            if (
                quote.quoteStatus == QuoteStatus.LOCKED ||
                quote.quoteStatus == QuoteStatus.CANCEL_PENDING
            ) {
                accountLayout.partyBNonces[quote.partyB][quote.partyA] += 1;
                accountLayout.partyBPendingLockedBalances[quote.partyB][quote.partyA].subQuote(
                    quote
                );
                removeFromPartyBPendingQuotes(quote);
            }
            quote.quoteStatus = QuoteStatus.EXPIRED;
            result = QuoteStatus.EXPIRED;
        } else if (
            quote.quoteStatus == QuoteStatus.CLOSE_PENDING ||
            quote.quoteStatus == QuoteStatus.CANCEL_CLOSE_PENDING
        ) {
            quote.modifyTimestamp = block.timestamp;
            accountLayout.partyANonces[quote.partyA] += 1;
            accountLayout.partyBNonces[quote.partyB][quote.partyA] += 1;
            quote.requestedClosePrice = 0;
            quote.quantityToClose = 0;
            quote.quoteStatus = QuoteStatus.OPENED;
            result = QuoteStatus.OPENED;
        }
    }
}
