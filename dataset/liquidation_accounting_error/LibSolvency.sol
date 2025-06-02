// SPDX-License-Identifier: SYMM-Core-Business-Source-License-1.1
// This contract is licensed under the SYMM Core Business Source License 1.1
// Copyright (c) 2023 Symmetry Labs AG
// For more information, see https://docs.symm.io/legal-disclaimer/license
pragma solidity >=0.8.18;

import "../storages/MuonStorage.sol";
import "../storages/QuoteStorage.sol";
import "./LibAccount.sol";
import "./LibQuote.sol";

library LibSolvency {
    using LockedValuesOps for LockedValues;

    function isSolventAfterOpenPosition(
        uint256 quoteId,
        uint256 filledAmount,
        PairUpnlAndPriceSig memory upnlSig
    ) internal view returns (bool) {
        Quote storage quote = QuoteStorage.layout().quotes[quoteId];
        int256 partyBAvailableBalance = LibAccount.partyBAvailableBalance(
            upnlSig.upnlPartyB,
            quote.partyB,
            quote.partyA
        );
        int256 partyAAvailableBalance = LibAccount.partyAAvailableBalance(
            upnlSig.upnlPartyA,
            quote.partyA
        );

        uint256 lockedAmount;
        uint256 lockedMM;
        if (quote.orderType == OrderType.LIMIT) {
            lockedAmount =
                (filledAmount * (quote.lockedValues.cva + quote.lockedValues.lf)) /
                quote.quantity;
            lockedMM = (filledAmount * quote.lockedValues.mm) / quote.quantity;
        } else {
            lockedAmount = quote.lockedValues.cva + quote.lockedValues.lf;
            lockedMM = quote.lockedValues.mm;
        }

        partyAAvailableBalance -= int256(lockedAmount);
        partyBAvailableBalance -= int256(lockedAmount);

        if (quote.positionType == PositionType.LONG) {
            if (quote.openedPrice >= upnlSig.price) {
                uint256 diff = (filledAmount * (quote.openedPrice - upnlSig.price)) / 1e18;
                uint256 max = diff > lockedMM ? diff : lockedMM;
                require(
                    partyAAvailableBalance - int256(max) >= 0,
                    "LibSolvency: PartyA will be liquidatable"
                );
                require(
                    partyBAvailableBalance + int256(diff) - int256(lockedMM) >= 0,
                    "LibSolvency: PartyB will be liquidatable"
                );
            } else {
                uint256 diff = (filledAmount * (upnlSig.price - quote.openedPrice)) / 1e18;
                uint256 max = diff > lockedMM ? diff : lockedMM;
                require(
                    partyBAvailableBalance - int256(max) >= 0,
                    "LibSolvency: PartyB will be liquidatable"
                );
                require(
                    partyAAvailableBalance + int256(diff) - int256(lockedMM) >= 0,
                    "LibSolvency: PartyA will be liquidatable"
                );
            }
        } else if (quote.positionType == PositionType.SHORT) {
            if (quote.openedPrice >= upnlSig.price) {
                uint256 diff = (filledAmount * (quote.openedPrice - upnlSig.price)) / 1e18;
                uint256 max = diff > lockedMM ? diff : lockedMM;
                require(
                    partyBAvailableBalance - int256(max) >= 0,
                    "LibSolvency: PartyB will be liquidatable"
                );
                require(
                    partyAAvailableBalance + int256(diff) - int256(lockedMM) >= 0,
                    "LibSolvency: PartyA will be liquidatable"
                );
            } else {
                uint256 diff = (filledAmount * (upnlSig.price - quote.openedPrice)) / 1e18;
                uint256 max = diff > lockedMM ? diff : lockedMM;
                require(
                    partyAAvailableBalance - int256(max) >= 0,
                    "LibSolvency: PartyA will be liquidatable"
                );
                require(
                    partyBAvailableBalance + int256(diff) - int256(lockedMM) >= 0,
                    "LibSolvency: PartyB will be liquidatable"
                );
            }
        }

        return true;
    }

    function isSolventAfterClosePosition(
        uint256 quoteId,
        uint256 filledAmount,
        uint256 closedPrice,
        PairUpnlAndPriceSig memory upnlSig
    ) internal view returns (bool) {
        Quote storage quote = QuoteStorage.layout().quotes[quoteId];
        uint256 unlockedAmount = (filledAmount * (quote.lockedValues.cva + quote.lockedValues.lf)) /
            LibQuote.quoteOpenAmount(quote);

        int256 partyBAvailableBalance = LibAccount.partyBAvailableBalanceForLiquidation(
            upnlSig.upnlPartyB,
            quote.partyB,
            quote.partyA
        ) + int256(unlockedAmount);

        int256 partyAAvailableBalance = LibAccount.partyAAvailableBalanceForLiquidation(
            upnlSig.upnlPartyA,
            quote.partyA
        ) + int256(unlockedAmount);

        require(
            partyBAvailableBalance >= 0 && partyAAvailableBalance >= 0,
            "LibSolvency: Available balance is lower than zero"
        );
        if (quote.positionType == PositionType.LONG) {
            if (closedPrice >= upnlSig.price) {
                require(
                    uint256(partyBAvailableBalance) >=
                        ((filledAmount * (closedPrice - upnlSig.price)) / 1e18),
                    "LibSolvency: PartyB will be liquidatable"
                );
            } else {
                require(
                    uint256(partyAAvailableBalance) >=
                        ((filledAmount * (upnlSig.price - closedPrice)) / 1e18),
                    "LibSolvency: PartyA will be liquidatable"
                );
            }
        } else if (quote.positionType == PositionType.SHORT) {
            if (closedPrice <= upnlSig.price) {
                require(
                    uint256(partyBAvailableBalance) >=
                        ((filledAmount * (upnlSig.price - closedPrice)) / 1e18),
                    "LibSolvency: PartyB will be liquidatable"
                );
            } else {
                require(
                    uint256(partyAAvailableBalance) >=
                        ((filledAmount * (closedPrice - upnlSig.price)) / 1e18),
                    "LibSolvency: PartyA will be liquidatable"
                );
            }
        }
        return true;
    }

    function isSolventAfterRequestToClosePosition(
        uint256 quoteId,
        uint256 closePrice,
        uint256 quantityToClose,
        SingleUpnlAndPriceSig memory upnlSig
    ) internal view returns (bool) {
        Quote storage quote = QuoteStorage.layout().quotes[quoteId];
        uint256 unlockedAmount = (quantityToClose *
            (quote.lockedValues.cva + quote.lockedValues.lf)) / LibQuote.quoteOpenAmount(quote);

        int256 availableBalance = LibAccount.partyAAvailableBalanceForLiquidation(
            upnlSig.upnl,
            msg.sender
        ) + int256(unlockedAmount);

        require(availableBalance >= 0, "LibSolvency: Available balance is lower than zero");
        if (quote.positionType == PositionType.LONG && closePrice <= upnlSig.price) {
            require(
                uint256(availableBalance) >=
                    ((quantityToClose * (upnlSig.price - closePrice)) / 1e18),
                "LibSolvency: partyA will be liquidatable"
            );
        } else if (quote.positionType == PositionType.SHORT && closePrice >= upnlSig.price) {
            require(
                uint256(availableBalance) >=
                    ((quantityToClose * (closePrice - upnlSig.price)) / 1e18),
                "LibSolvency: partyA will be liquidatable"
            );
        }
        return true;
    }
}