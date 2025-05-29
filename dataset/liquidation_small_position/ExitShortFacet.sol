// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.21;

import {U256, U80, U88} from "contracts/libraries/PRBMathHelper.sol";

import {IDiamond} from "interfaces/IDiamond.sol";

import {Modifiers} from "contracts/libraries/AppStorage.sol";
import {Errors} from "contracts/libraries/Errors.sol";
import {Events} from "contracts/libraries/Events.sol";
import {STypes, MTypes, OF} from "contracts/libraries/DataTypes.sol";
import {LibAsset} from "contracts/libraries/LibAsset.sol";
import {LibOracle} from "contracts/libraries/LibOracle.sol";
import {LibOrders} from "contracts/libraries/LibOrders.sol";
import {LibShortRecord} from "contracts/libraries/LibShortRecord.sol";
import {Constants} from "contracts/libraries/Constants.sol";

// import {console} from "contracts/libraries/console.sol";

contract ExitShortFacet is Modifiers {
    using U256 for uint256;
    using U80 for uint80;
    using U88 for uint88;
    using LibShortRecord for STypes.ShortRecord;
    using {LibAsset.burnMsgSenderDebt} for address;

    address private immutable cusd;

    constructor(address _cusd) {
        cusd = _cusd;
    }

    /**
     * @notice Exits a short using shorter's ERC in wallet (i.e.MetaMask)
     * @dev allows for partial exit via buyBackAmount
     *
     * @param asset The market that will be impacted
     * @param id Id of short
     * @param buyBackAmount Erc amount to buy back
     *
     */

    function exitShortWallet(address asset, uint8 id, uint88 buyBackAmount)
        external
        isNotFrozen(asset)
        nonReentrant
        onlyValidShortRecord(asset, msg.sender, id)
    {
        STypes.ShortRecord storage short = s.shortRecords[asset][msg.sender][id];

        short.updateErcDebt(asset);
        uint256 ercDebt = short.ercDebt;
        if (buyBackAmount > ercDebt || buyBackAmount == 0) revert Errors.InvalidBuyback();

        if (ercDebt > buyBackAmount) {
            uint256 leftoverAmt = (ercDebt - buyBackAmount).mul(LibOracle.getPrice(asset));
            if (leftoverAmt < LibAsset.minBidEth(asset)) {
                revert Errors.CannotLeaveDustAmount();
            }
        }

        asset.burnMsgSenderDebt(buyBackAmount);
        s.asset[asset].ercDebt -= buyBackAmount;
        // refund the rest of the collateral if ercDebt is fully paid back
        if (buyBackAmount == ercDebt) {
            uint256 vault = s.asset[asset].vault;
            uint88 collateral = short.collateral;
            s.vaultUser[vault][msg.sender].ethEscrowed += collateral;
            LibShortRecord.disburseCollateral(
                asset, msg.sender, collateral, short.zethYieldRate, short.updatedAt
            );
            LibShortRecord.deleteShortRecord(asset, msg.sender, id);
        } else {
            short.ercDebt -= buyBackAmount;
            short.maybeResetFlag(asset);
        }
        emit Events.ExitShortWallet(asset, msg.sender, id, buyBackAmount);
    }

    /**
     * @notice Exits a short using shorter's ERC in balance (ErcEscrowed)
     * @dev allows for partial exit via buyBackAmount
     *
     * @param asset The market that will be impacted
     * @param id Id of short
     * @param buyBackAmount Erc amount to buy back
     *
     */

    function exitShortErcEscrowed(address asset, uint8 id, uint88 buyBackAmount)
        external
        isNotFrozen(asset)
        nonReentrant
        onlyValidShortRecord(asset, msg.sender, id)
    {
        STypes.Asset storage Asset = s.asset[asset];

        STypes.ShortRecord storage short = s.shortRecords[asset][msg.sender][id];

        short.updateErcDebt(asset);
        uint256 ercDebt = short.ercDebt;
        if (buyBackAmount == 0 || buyBackAmount > ercDebt) revert Errors.InvalidBuyback();

        STypes.AssetUser storage AssetUser = s.assetUser[asset][msg.sender];
        if (AssetUser.ercEscrowed < buyBackAmount) {
            revert Errors.InsufficientERCEscrowed();
        }

        if (ercDebt > buyBackAmount) {
            uint256 leftoverAmt = (ercDebt - buyBackAmount).mul(LibOracle.getPrice(asset));
            if (leftoverAmt < LibAsset.minBidEth(asset)) {
                revert Errors.CannotLeaveDustAmount();
            }
        }

        AssetUser.ercEscrowed -= buyBackAmount;
        Asset.ercDebt -= buyBackAmount;
        // refund the rest of the collateral if ercDebt is fully paid back
        if (ercDebt == buyBackAmount) {
            uint88 collateral = short.collateral;
            s.vaultUser[Asset.vault][msg.sender].ethEscrowed += collateral;
            LibShortRecord.disburseCollateral(
                asset, msg.sender, collateral, short.zethYieldRate, short.updatedAt
            );
            LibShortRecord.deleteShortRecord(asset, msg.sender, id);
        } else {
            short.ercDebt -= buyBackAmount;
            short.maybeResetFlag(asset);
        }
        emit Events.ExitShortErcEscrowed(asset, msg.sender, id, buyBackAmount);
    }

    /**
     * @notice Exits a short by placing bid on market
     * @dev allows for partial exit via buyBackAmount
     *
     * @param asset The market that will be impacted
     * @param id Id of short
     * @param buyBackAmount Erc amount to buy back
     * @param price Price at which shorter wants to place bid
     * @param shortHintArray Array of hintId for the id to start matching against shorts since you can't match a short < oracle price
     *
     */

    function exitShort(
        address asset,
        uint8 id,
        uint88 buyBackAmount,
        uint80 price,
        uint16[] memory shortHintArray
    )
        external
        isNotFrozen(asset)
        nonReentrant
        onlyValidShortRecord(asset, msg.sender, id)
    {
        MTypes.ExitShort memory e;
        e.asset = asset;
        LibOrders.updateOracleAndStartingShortViaTimeBidOnly(
            e.asset, OF.FifteenMinutes, shortHintArray
        );

        STypes.Asset storage Asset = s.asset[e.asset];
        STypes.ShortRecord storage short = s.shortRecords[e.asset][msg.sender][id];

        short.updateErcDebt(e.asset);

        e.beforeExitCR = short.getCollateralRatio(e.asset);
        e.ercDebt = short.ercDebt;
        e.collateral = short.collateral;

        if (buyBackAmount == 0 || buyBackAmount > e.ercDebt) {
            revert Errors.InvalidBuyback();
        }
        if (e.ercDebt > buyBackAmount) {
            uint256 leftoverAmt = (e.ercDebt - buyBackAmount).mul(price);
            if (leftoverAmt < LibAsset.minBidEth(e.asset)) {
                revert Errors.CannotLeaveDustAmount();
            }
        }

        {
            uint256 ethAmount = price.mul(buyBackAmount);
            if (ethAmount > e.collateral) revert Errors.InsufficientCollateral();
        }

        {
            uint16 lowestAskKey = s.asks[e.asset][Constants.HEAD].nextId;
            uint16 startingShortId = s.asset[e.asset].startingShortId;

            if (
                (
                    lowestAskKey == Constants.TAIL
                        || s.asks[e.asset][lowestAskKey].price > price
                )
                    && (
                        startingShortId == Constants.HEAD
                            || s.shorts[e.asset][startingShortId].price > price
                    )
            ) {
                revert Errors.ExitShortPriceTooLow();
            }
        }

        // Temporary accounting to enable bid
        STypes.VaultUser storage VaultUser = s.vaultUser[Asset.vault][msg.sender];
        VaultUser.ethEscrowed += e.collateral;

        // Create bid with current msg.sender
        (e.ethFilled, e.ercAmountLeft) = IDiamond(payable(address(this))).createForcedBid(
            msg.sender, e.asset, price, buyBackAmount, shortHintArray
        );

        e.ercFilled = buyBackAmount - e.ercAmountLeft;
        Asset.ercDebt -= e.ercFilled;
        s.assetUser[e.asset][msg.sender].ercEscrowed -= e.ercFilled;

        // Refund the rest of the collateral if ercDebt is fully paid back
        if (e.ercDebt == e.ercFilled) {
            // Full Exit
            LibShortRecord.disburseCollateral(
                e.asset, msg.sender, e.collateral, short.zethYieldRate, short.updatedAt
            );
            LibShortRecord.deleteShortRecord(e.asset, msg.sender, id); // prevent re-entrancy
        } else {
            short.collateral -= e.ethFilled;
            short.ercDebt -= e.ercFilled;

            //@dev Only allow partial exit if the CR is same or better than before
            if (short.getCollateralRatio(e.asset) < e.beforeExitCR) {
                revert Errors.PostExitCRLtPreExitCR();
            }

            //@dev collateral already subtracted in exitShort()
            VaultUser.ethEscrowed -= e.collateral - e.ethFilled;
            LibShortRecord.disburseCollateral(
                e.asset, msg.sender, e.ethFilled, short.zethYieldRate, short.updatedAt
            );
            short.maybeResetFlag(e.asset);
        }
        emit Events.ExitShort(asset, msg.sender, id, e.ercFilled);
    }
}
