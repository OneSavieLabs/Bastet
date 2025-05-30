// SPDX-License-Identifier: SYMM-Core-Business-Source-License-1.1
// This contract is licensed under the SYMM Core Business Source License 1.1
// Copyright (c) 2023 Symmetry Labs AG
// For more information, see https://docs.symm.io/legal-disclaimer/license
pragma solidity >=0.8.18;

import "../../libraries/muon/LibMuonForceActions.sol";
import "../../libraries/muon/LibMuonSettlement.sol";
import "../../libraries/LibSettlement.sol";
import "../../libraries/LibLiquidation.sol";
import "../../libraries/LibSolvency.sol";
import "../../storages/QuoteStorage.sol";
import "../Settlement/SettlementFacetEvents.sol";

library ForceActionsFacetImpl {
	using LockedValuesOps for LockedValues;

	function forceCancelQuote(uint256 quoteId) internal {
		AccountStorage.Layout storage accountLayout = AccountStorage.layout();
		MAStorage.Layout storage maLayout = MAStorage.layout();
		Quote storage quote = QuoteStorage.layout().quotes[quoteId];

		require(quote.quoteStatus == QuoteStatus.CANCEL_PENDING, "PartyAFacet: Invalid state");
		require(block.timestamp > quote.statusModifyTimestamp + maLayout.forceCancelCooldown, "PartyAFacet: Cooldown not reached");
		quote.statusModifyTimestamp = block.timestamp;
		quote.quoteStatus = QuoteStatus.CANCELED;
		accountLayout.pendingLockedBalances[quote.partyA].subQuote(quote);
		accountLayout.partyBPendingLockedBalances[quote.partyB][quote.partyA].subQuote(quote);

		// send trading Fee back to partyA
		uint256 fee = LibQuote.getTradingFee(quote.id);
		accountLayout.allocatedBalances[quote.partyA] += fee;
		emit SharedEvents.BalanceChangePartyA(quote.partyA, fee, SharedEvents.BalanceChangeType.PLATFORM_FEE_IN);

		LibQuote.removeFromPendingQuotes(quote);
	}

	function forceCancelCloseRequest(uint256 quoteId) internal {
		MAStorage.Layout storage maLayout = MAStorage.layout();
		Quote storage quote = QuoteStorage.layout().quotes[quoteId];

		require(quote.quoteStatus == QuoteStatus.CANCEL_CLOSE_PENDING, "PartyAFacet: Invalid state");
		require(block.timestamp > quote.statusModifyTimestamp + maLayout.forceCancelCloseCooldown, "PartyAFacet: Cooldown not reached");

		quote.statusModifyTimestamp = block.timestamp;
		quote.quoteStatus = QuoteStatus.OPENED;
		quote.requestedClosePrice = 0;
		quote.quantityToClose = 0;
	}

	function forceClosePosition(
		uint256 quoteId,
		HighLowPriceSig memory sig,
		SettlementSig memory settlementSig,
		uint256[] memory updatedPrices
	) internal returns (uint256 closePrice, bool isPartyBLiquidated, int256 upnlPartyB, uint256 partyBAllocatedBalance) {
		MAStorage.Layout storage maLayout = MAStorage.layout();
		AccountStorage.Layout storage accountLayout = AccountStorage.layout();
		SymbolStorage.Layout storage symbolLayout = SymbolStorage.layout();
		Quote storage quote = QuoteStorage.layout().quotes[quoteId];
		require(quote.quoteStatus == QuoteStatus.CLOSE_PENDING, "PartyAFacet: Invalid state");
		require(sig.endTime + maLayout.forceCloseSecondCooldown <= quote.deadline, "PartyBFacet: Close request is expired");
		require(quote.orderType == OrderType.LIMIT, "PartyBFacet: Quote's order type should be LIMIT");
		require(sig.startTime >= quote.statusModifyTimestamp + maLayout.forceCloseFirstCooldown, "PartyAFacet: Cooldown not reached");
		require(sig.endTime <= block.timestamp - maLayout.forceCloseSecondCooldown, "PartyAFacet: Cooldown not reached");
		require(sig.averagePrice <= sig.highest && sig.averagePrice >= sig.lowest, "PartyAFacet: Invalid average price");
		if (quote.positionType == PositionType.LONG) {
			require(
				sig.highest >= quote.requestedClosePrice + (quote.requestedClosePrice * symbolLayout.forceCloseGapRatio[quote.symbolId]) / 1e18,
				"PartyAFacet: Requested close price not reached"
			);
			closePrice = quote.requestedClosePrice + (quote.requestedClosePrice * maLayout.forceClosePricePenalty) / 1e18;
			closePrice = closePrice > sig.averagePrice ? closePrice : sig.averagePrice; // max
		} else {
			require(
				sig.lowest <= quote.requestedClosePrice - (quote.requestedClosePrice * symbolLayout.forceCloseGapRatio[quote.symbolId]) / 1e18,
				"PartyAFacet: Requested close price not reached"
			);
			closePrice = quote.requestedClosePrice - (quote.requestedClosePrice * maLayout.forceClosePricePenalty) / 1e18;
			closePrice = closePrice > sig.averagePrice ? sig.averagePrice : closePrice; // min
		}

		if (closePrice == sig.averagePrice)
			require(sig.endTime - sig.startTime >= maLayout.forceCloseMinSigPeriod, "PartyAFacet: Invalid signature period");

		LibMuonForceActions.verifyHighLowPrice(sig, quote.partyB, quote.partyA, quote.symbolId);
		if (updatedPrices.length > 0) {
			LibMuonSettlement.verifySettlement(settlementSig, quote.partyA);
		}
		accountLayout.partyANonces[quote.partyA] += 1;
		accountLayout.partyBNonces[quote.partyB][quote.partyA] += 1;
		uint256 reserveAmount = accountLayout.reserveVault[quote.partyB];

		uint256[] memory quoteIds = new uint256[](1);
		uint256[] memory filledAmounts = new uint256[](1);
		uint256[] memory closedPrices = new uint256[](1);
		uint256[] memory marketPrices = new uint256[](1);
		quoteIds[0] = quoteId;
		filledAmounts[0] = quote.quantityToClose;
		closedPrices[0] = closePrice;
		marketPrices[0] = sig.currentPrice;
		(int256 partyBAvailableBalance, int256 partyAAvailableBalance) = LibSolvency.getAvailableBalanceAfterClosePosition(
			quoteIds,
			filledAmounts,
			closedPrices,
			marketPrices,
			sig.upnlPartyB,
			sig.upnlPartyA,
			quote.partyB,
			quote.partyA
		);
		require(partyAAvailableBalance >= 0, "PartyAFacet: PartyA will be insolvent");
		if (partyBAvailableBalance >= 0) {
			if (updatedPrices.length > 0) {
				LibSettlement.settleUpnl(settlementSig, updatedPrices, msg.sender, true);
			}
			LibQuote.closeQuote(quote, quote.quantityToClose, closePrice);
		} else if (partyBAvailableBalance + int256(reserveAmount) >= 0) {
			uint256 available = uint256(-partyBAvailableBalance);
			accountLayout.reserveVault[quote.partyB] -= available;
			accountLayout.partyBAllocatedBalances[quote.partyB][quote.partyA] += available;
			emit SharedEvents.BalanceChangePartyB(quote.partyB, quote.partyA, available, SharedEvents.BalanceChangeType.REALIZED_PNL_IN);
			if (updatedPrices.length > 0) {
				LibSettlement.settleUpnl(settlementSig, updatedPrices, msg.sender, true);
			}
			LibQuote.closeQuote(quote, quote.quantityToClose, closePrice);
		} else {
			accountLayout.reserveVault[quote.partyB] = 0;
			accountLayout.partyBAllocatedBalances[quote.partyB][quote.partyA] += reserveAmount;
			emit SharedEvents.BalanceChangePartyB(quote.partyB, quote.partyA, reserveAmount, SharedEvents.BalanceChangeType.REALIZED_PNL_IN);
			int256 diff = (int256(quote.quantityToClose) * (int256(closePrice) - int256(sig.currentPrice))) / 1e18;
			if (quote.positionType == PositionType.LONG) {
				diff = diff * -1;
			}
			isPartyBLiquidated = true;
			upnlPartyB = sig.upnlPartyB + diff;
			LibLiquidation.liquidatePartyB(quote.partyB, quote.partyA, upnlPartyB, block.timestamp);
		}
		partyBAllocatedBalance = AccountStorage.layout().partyBAllocatedBalances[quote.partyB][quote.partyA];
	}
}
