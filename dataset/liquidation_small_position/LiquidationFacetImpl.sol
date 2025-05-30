// SPDX-License-Identifier: SYMM-Core-Business-Source-License-1.1
// This contract is licensed under the SYMM Core Business Source License 1.1
// Copyright (c) 2023 Symmetry Labs AG
// For more information, see https://docs.symm.io/legal-disclaimer/license
pragma solidity >=0.8.18;

import "../../libraries/LibLockedValues.sol";
import "../../libraries/LibMuon.sol";
import "../../libraries/LibAccount.sol";
import "../../libraries/LibQuote.sol";
import "../../storages/MAStorage.sol";
import "../../storages/QuoteStorage.sol";
import "../../storages/MuonStorage.sol";
import "../../storages/AccountStorage.sol";
import "../../storages/SymbolStorage.sol";

library LiquidationFacetImpl {
    using LockedValuesOps for LockedValues;

    function liquidatePartyA(address partyA, SingleUpnlSig memory upnlSig) internal {
        MAStorage.Layout storage maLayout = MAStorage.layout();

        LibMuon.verifyPartyAUpnl(upnlSig, partyA);
        int256 availableBalance = LibAccount.partyAAvailableBalanceForLiquidation(
            upnlSig.upnl,
            partyA
        );
        require(availableBalance < 0, "LiquidationFacet: PartyA is solvent");
        maLayout.liquidationStatus[partyA] = true;
        maLayout.liquidationTimestamp[partyA] = upnlSig.timestamp;
        AccountStorage.layout().liquidators[partyA].push(msg.sender);
    }

    function setSymbolsPrice(address partyA, PriceSig memory priceSig) internal {
        MAStorage.Layout storage maLayout = MAStorage.layout();
        AccountStorage.Layout storage accountLayout = AccountStorage.layout();

        LibMuon.verifyPrices(priceSig, partyA);
        require(maLayout.liquidationStatus[partyA], "LiquidationFacet: PartyA is solvent");
        require(
            priceSig.timestamp <=
                maLayout.liquidationTimestamp[partyA] + maLayout.liquidationTimeout,
            "LiquidationFacet: Expired signature"
        );
        for (uint256 index = 0; index < priceSig.symbolIds.length; index++) {
            accountLayout.symbolsPrices[partyA][priceSig.symbolIds[index]] = Price(
                priceSig.prices[index],
                maLayout.liquidationTimestamp[partyA]
            );
        }

        int256 availableBalance = LibAccount.partyAAvailableBalanceForLiquidation(
            priceSig.upnl,
            partyA
        );
        if (accountLayout.liquidationDetails[partyA].liquidationType == LiquidationType.NONE) {
            accountLayout.liquidationDetails[partyA] = LiquidationDetail({
                liquidationType: LiquidationType.NONE,
                upnl: priceSig.upnl,
                totalUnrealizedLoss: priceSig.totalUnrealizedLoss,
                deficit: 0,
                liquidationFee: 0
            });
            if (availableBalance >= 0) {
                uint256 remainingLf = accountLayout.lockedBalances[partyA].lf;
                accountLayout.liquidationDetails[partyA].liquidationType = LiquidationType.NORMAL;
                accountLayout.liquidationDetails[partyA].liquidationFee = remainingLf;
            } else if (uint256(-availableBalance) < accountLayout.lockedBalances[partyA].lf) {
                uint256 remainingLf = accountLayout.lockedBalances[partyA].lf -
                    uint256(-availableBalance);
                accountLayout.liquidationDetails[partyA].liquidationType = LiquidationType.NORMAL;
                accountLayout.liquidationDetails[partyA].liquidationFee = remainingLf;
            } else if (
                uint256(-availableBalance) <=
                accountLayout.lockedBalances[partyA].lf + accountLayout.lockedBalances[partyA].cva
            ) {
                uint256 deficit = uint256(-availableBalance) -
                    accountLayout.lockedBalances[partyA].lf;
                accountLayout.liquidationDetails[partyA].liquidationType = LiquidationType.LATE;
                accountLayout.liquidationDetails[partyA].deficit = deficit;
            } else {
                uint256 deficit = uint256(-availableBalance) -
                    accountLayout.lockedBalances[partyA].lf -
                    accountLayout.lockedBalances[partyA].cva;
                accountLayout.liquidationDetails[partyA].liquidationType = LiquidationType.OVERDUE;
                accountLayout.liquidationDetails[partyA].deficit = deficit;
            }
            AccountStorage.layout().liquidators[partyA].push(msg.sender);
        } else {
            require(
                accountLayout.liquidationDetails[partyA].upnl == priceSig.upnl &&
                    accountLayout.liquidationDetails[partyA].totalUnrealizedLoss ==
                    priceSig.totalUnrealizedLoss,
                "LiquidationFacet: Invalid upnl sig"
            );
        }
    }

    function liquidatePendingPositionsPartyA(address partyA) internal {
        QuoteStorage.Layout storage quoteLayout = QuoteStorage.layout();
        require(
            MAStorage.layout().liquidationStatus[partyA],
            "LiquidationFacet: PartyA is solvent"
        );
        for (uint256 index = 0; index < quoteLayout.partyAPendingQuotes[partyA].length; index++) {
            Quote storage quote = quoteLayout.quotes[
                quoteLayout.partyAPendingQuotes[partyA][index]
            ];
            if (
                (quote.quoteStatus == QuoteStatus.LOCKED ||
                    quote.quoteStatus == QuoteStatus.CANCEL_PENDING) &&
                quoteLayout.partyBPendingQuotes[quote.partyB][partyA].length > 0
            ) {
                delete quoteLayout.partyBPendingQuotes[quote.partyB][partyA];
                AccountStorage
                .layout()
                .partyBPendingLockedBalances[quote.partyB][partyA].makeZero();
            }
            quote.quoteStatus = QuoteStatus.LIQUIDATED;
            quote.modifyTimestamp = block.timestamp;
        }
        AccountStorage.layout().pendingLockedBalances[partyA].makeZero();
        delete quoteLayout.partyAPendingQuotes[partyA];
    }

    function liquidatePositionsPartyA(
        address partyA,
        uint256[] memory quoteIds
    ) internal returns (bool) {
        AccountStorage.Layout storage accountLayout = AccountStorage.layout();
        MAStorage.Layout storage maLayout = MAStorage.layout();
        QuoteStorage.Layout storage quoteLayout = QuoteStorage.layout();

        require(maLayout.liquidationStatus[partyA], "LiquidationFacet: PartyA is solvent");
        for (uint256 index = 0; index < quoteIds.length; index++) {
            Quote storage quote = quoteLayout.quotes[quoteIds[index]];
            require(
                quote.quoteStatus == QuoteStatus.OPENED ||
                    quote.quoteStatus == QuoteStatus.CLOSE_PENDING ||
                    quote.quoteStatus == QuoteStatus.CANCEL_CLOSE_PENDING,
                "LiquidationFacet: Invalid state"
            );
            require(quote.partyA == partyA, "LiquidationFacet: Invalid party");
            require(
                accountLayout.symbolsPrices[partyA][quote.symbolId].timestamp ==
                    maLayout.liquidationTimestamp[partyA],
                "LiquidationFacet: Price should be set"
            );
            quote.quoteStatus = QuoteStatus.LIQUIDATED;
            quote.modifyTimestamp = block.timestamp;

            (bool hasMadeProfit, uint256 amount) = LibQuote.getValueOfQuoteForPartyA(
                accountLayout.symbolsPrices[partyA][quote.symbolId].price,
                LibQuote.quoteOpenAmount(quote),
                quote
            );
            if (hasMadeProfit) {
                accountLayout.totalUnplForLiquidation[partyA] += int256(amount);
            } else {
                accountLayout.totalUnplForLiquidation[partyA] -= int256(amount);
            }

            if (
                accountLayout.liquidationDetails[partyA].liquidationType == LiquidationType.NORMAL
            ) {
                accountLayout.partyBAllocatedBalances[quote.partyB][partyA] += quote
                    .lockedValues
                    .cva;
                if (hasMadeProfit) {
                    accountLayout.partyBAllocatedBalances[quote.partyB][partyA] -= amount;
                } else {
                    accountLayout.partyBAllocatedBalances[quote.partyB][partyA] += amount;
                }
            } else if (
                accountLayout.liquidationDetails[partyA].liquidationType == LiquidationType.LATE
            ) {
                accountLayout.partyBAllocatedBalances[quote.partyB][partyA] +=
                    quote.lockedValues.cva -
                    ((quote.lockedValues.cva * accountLayout.liquidationDetails[partyA].deficit) /
                        accountLayout.lockedBalances[partyA].cva);
                if (hasMadeProfit) {
                    accountLayout.partyBAllocatedBalances[quote.partyB][partyA] -= amount;
                } else {
                    accountLayout.partyBAllocatedBalances[quote.partyB][partyA] += amount;
                }
            } else if (
                accountLayout.liquidationDetails[partyA].liquidationType == LiquidationType.OVERDUE
            ) {
                if (hasMadeProfit) {
                    accountLayout.partyBAllocatedBalances[quote.partyB][partyA] -= amount;
                } else {
                    accountLayout.partyBAllocatedBalances[quote.partyB][partyA] +=
                        amount -
                        ((amount * accountLayout.liquidationDetails[partyA].deficit) /
                            uint256(-accountLayout.liquidationDetails[partyA].totalUnrealizedLoss));
                }
            }
            accountLayout.partyBLockedBalances[quote.partyB][partyA].subQuote(quote);
            quote.avgClosedPrice =
                (quote.avgClosedPrice *
                    quote.closedAmount +
                    LibQuote.quoteOpenAmount(quote) *
                    accountLayout.symbolsPrices[partyA][quote.symbolId].price) /
                (quote.closedAmount + LibQuote.quoteOpenAmount(quote));
            quote.closedAmount = quote.quantity;

            LibQuote.removeFromOpenPositions(quote.id);
            quoteLayout.partyAPositionsCount[partyA] -= 1;
            quoteLayout.partyBPositionsCount[quote.partyB][partyA] -= 1;
        }
        if (quoteLayout.partyAPositionsCount[partyA] == 0) {
            require(
                quoteLayout.partyAPendingQuotes[partyA].length == 0,
                "LiquidationFacet: Pending quotes should be liquidated first"
            );
            accountLayout.allocatedBalances[partyA] = 0;
            accountLayout.lockedBalances[partyA].makeZero();

            uint256 lf = accountLayout.liquidationDetails[partyA].liquidationFee;
            if (lf > 0) {
                accountLayout.allocatedBalances[accountLayout.liquidators[partyA][0]] += lf / 2;
                accountLayout.allocatedBalances[accountLayout.liquidators[partyA][1]] += lf / 2;
            }
            delete accountLayout.liquidators[partyA];
            maLayout.liquidationStatus[partyA] = false;
            maLayout.liquidationTimestamp[partyA] = 0;
            accountLayout.liquidationDetails[partyA].liquidationType = LiquidationType.NONE;
            if (
                accountLayout.totalUnplForLiquidation[partyA] !=
                accountLayout.liquidationDetails[partyA].upnl
            ) {
                accountLayout.totalUnplForLiquidation[partyA] = 0;
                return false;
            }
            accountLayout.totalUnplForLiquidation[partyA] = 0;
        }
        return true;
    }

    function liquidatePartyB(
        address partyB,
        address partyA,
        SingleUpnlSig memory upnlSig
    ) internal {
        AccountStorage.Layout storage accountLayout = AccountStorage.layout();
        MAStorage.Layout storage maLayout = MAStorage.layout();
        QuoteStorage.Layout storage quoteLayout = QuoteStorage.layout();

        LibMuon.verifyPartyBUpnl(upnlSig, partyB, partyA);
        int256 availableBalance = LibAccount.partyBAvailableBalanceForLiquidation(
            upnlSig.upnl,
            partyB,
            partyA
        );

        require(availableBalance < 0, "LiquidationFacet: partyB is solvent");
        uint256 liquidatorShare;
        uint256 remainingLf;
        if (uint256(-availableBalance) < accountLayout.partyBLockedBalances[partyB][partyA].lf) {
            remainingLf =
                accountLayout.partyBLockedBalances[partyB][partyA].lf -
                uint256(-availableBalance);
            liquidatorShare = (remainingLf * maLayout.liquidatorShare) / 1e18;

            maLayout.partyBPositionLiquidatorsShare[partyB][partyA] =
                (remainingLf - liquidatorShare) /
                quoteLayout.partyBPositionsCount[partyB][partyA];
        } else {
            maLayout.partyBPositionLiquidatorsShare[partyB][partyA] = 0;
        }

        maLayout.partyBLiquidationStatus[partyB][partyA] = true;
        maLayout.partyBLiquidationTimestamp[partyB][partyA] = upnlSig.timestamp;

        uint256[] storage pendingQuotes = quoteLayout.partyAPendingQuotes[partyA];

        for (uint256 index = 0; index < pendingQuotes.length; ) {
            Quote storage quote = quoteLayout.quotes[pendingQuotes[index]];
            if (
                quote.partyB == partyB &&
                (quote.quoteStatus == QuoteStatus.LOCKED ||
                    quote.quoteStatus == QuoteStatus.CANCEL_PENDING)
            ) {
                accountLayout.pendingLockedBalances[partyA].subQuote(quote);

                pendingQuotes[index] = pendingQuotes[pendingQuotes.length - 1];
                pendingQuotes.pop();
                quote.quoteStatus = QuoteStatus.LIQUIDATED;
                quote.modifyTimestamp = block.timestamp;
            } else {
                index++;
            }
        }
        accountLayout.allocatedBalances[partyA] +=
            accountLayout.partyBAllocatedBalances[partyB][partyA] -
            remainingLf;

        delete quoteLayout.partyBPendingQuotes[partyB][partyA];
        accountLayout.partyBAllocatedBalances[partyB][partyA] = 0;
        accountLayout.partyBLockedBalances[partyB][partyA].makeZero();
        accountLayout.partyBPendingLockedBalances[partyB][partyA].makeZero();

        if (liquidatorShare > 0) {
            accountLayout.allocatedBalances[msg.sender] += liquidatorShare;
        }
    }

    function liquidatePositionsPartyB(
        address partyB,
        address partyA,
        QuotePriceSig memory priceSig
    ) internal {
        AccountStorage.Layout storage accountLayout = AccountStorage.layout();
        MAStorage.Layout storage maLayout = MAStorage.layout();
        QuoteStorage.Layout storage quoteLayout = QuoteStorage.layout();

        LibMuon.verifyQuotePrices(priceSig);
        require(
            priceSig.timestamp <=
                maLayout.partyBLiquidationTimestamp[partyB][partyA] + maLayout.liquidationTimeout,
            "LiquidationFacet: Expired signature"
        );
        require(
            maLayout.partyBLiquidationStatus[partyB][partyA],
            "LiquidationFacet: PartyB is solvent"
        );
        require(
            block.timestamp <= priceSig.timestamp + maLayout.liquidationTimeout,
            "LiquidationFacet: Expired price sig"
        );
        for (uint256 index = 0; index < priceSig.quoteIds.length; index++) {
            Quote storage quote = quoteLayout.quotes[priceSig.quoteIds[index]];
            require(
                quote.quoteStatus == QuoteStatus.OPENED ||
                    quote.quoteStatus == QuoteStatus.CLOSE_PENDING ||
                    quote.quoteStatus == QuoteStatus.CANCEL_CLOSE_PENDING,
                "LiquidationFacet: Invalid state"
            );
            require(
                quote.partyA == partyA && quote.partyB == partyB,
                "LiquidationFacet: Invalid party"
            );

            quote.quoteStatus = QuoteStatus.LIQUIDATED;
            quote.modifyTimestamp = block.timestamp;

            // accountLayout.allocatedBalances[partyA] += quote.lockedValues.cva;
            accountLayout.lockedBalances[partyA].subQuote(quote);

            // (bool hasMadeProfit, uint256 amount) = LibQuote.getValueOfQuoteForPartyA(
            //     priceSig.prices[index],
            //     LibQuote.quoteOpenAmount(quote),
            //     quote
            // );

            // if (hasMadeProfit) {
            //     accountLayout.allocatedBalances[partyA] += amount;
            // } else {
            //     accountLayout.allocatedBalances[partyA] -= amount;
            // }
            quote.avgClosedPrice =
                (quote.avgClosedPrice *
                    quote.closedAmount +
                    LibQuote.quoteOpenAmount(quote) *
                    priceSig.prices[index]) /
                (quote.closedAmount + LibQuote.quoteOpenAmount(quote));
            quote.closedAmount = quote.quantity;

            LibQuote.removeFromOpenPositions(quote.id);
            quoteLayout.partyAPositionsCount[partyA] -= 1;
            quoteLayout.partyBPositionsCount[partyB][partyA] -= 1;
        }
        if (maLayout.partyBPositionLiquidatorsShare[partyB][partyA] > 0) {
            accountLayout.allocatedBalances[msg.sender] +=
                maLayout.partyBPositionLiquidatorsShare[partyB][partyA] *
                priceSig.quoteIds.length;
        }

        if (quoteLayout.partyBPositionsCount[partyB][partyA] == 0) {
            maLayout.partyBLiquidationStatus[partyB][partyA] = false;
            maLayout.partyBLiquidationTimestamp[partyB][partyA] = 0;
        }
    }
}
