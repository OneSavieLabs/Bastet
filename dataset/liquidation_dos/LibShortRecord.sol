// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.21;

import {U256, U88, U80} from "contracts/libraries/PRBMathHelper.sol";

import {STypes, SR} from "contracts/libraries/DataTypes.sol";
import {Errors} from "contracts/libraries/Errors.sol";
import {Events} from "contracts/libraries/Events.sol";
import {AppStorage, appStorage} from "contracts/libraries/AppStorage.sol";
import {Constants} from "contracts/libraries/Constants.sol";
import {LibAsset} from "contracts/libraries/LibAsset.sol";
import {LibOrders} from "contracts/libraries/LibOrders.sol";
import {LibOracle} from "contracts/libraries/LibOracle.sol";

// import {console} from "contracts/libraries/console.sol";

library LibShortRecord {
    using U256 for uint256;
    using U88 for uint88;
    using U80 for uint80;

    function getCollateralRatio(STypes.ShortRecord memory short, address asset)
        internal
        view
        returns (uint256 cRatio)
    {
        return short.collateral.div(short.ercDebt.mul(LibOracle.getPrice(asset)));
    }

    function getCollateralRatioSpotPrice(
        STypes.ShortRecord memory short,
        uint256 oraclePrice
    ) internal pure returns (uint256 cRatio) {
        return short.collateral.div(short.ercDebt.mul(oraclePrice));
    }

    /**
     * @notice Returns number of active shortRecords
     *
     * @param asset The market that will be impacted
     * @param shorter Shorter address
     *
     * @return shortRecordCount
     */
    function getShortRecordCount(address asset, address shorter)
        internal
        view
        returns (uint256 shortRecordCount)
    {
        AppStorage storage s = appStorage();

        // Retrieve first non-HEAD short
        uint8 id = s.shortRecords[asset][shorter][Constants.HEAD].nextId;
        if (id <= Constants.HEAD) {
            return 0;
        }

        while (true) {
            shortRecordCount++;
            // One short of one shorter in this order book
            STypes.ShortRecord storage currentShort = s.shortRecords[asset][shorter][id];
            // Move to next short unless this is the last one
            if (currentShort.nextId > Constants.HEAD) {
                id = currentShort.nextId;
            } else {
                return shortRecordCount;
            }
        }
    }

    function createShortRecord(
        address asset,
        address shorter,
        SR status,
        uint88 collateral,
        uint88 ercAmount,
        uint64 ercDebtRate,
        uint80 zethYieldRate,
        uint40 tokenId
    ) internal returns (uint8 id) {
        AppStorage storage s = appStorage();

        // ensure the tokenId can be downcasted to 40 bits
        if (tokenId > type(uint40).max) revert Errors.InvalidTokenId();

        uint8 nextId;
        (id, nextId) = setShortRecordIds(asset, shorter);

        if (id <= Constants.SHORT_MAX_ID) {
            s.shortRecords[asset][shorter][id] = STypes.ShortRecord({
                prevId: Constants.HEAD,
                id: id,
                nextId: nextId,
                status: status,
                collateral: collateral,
                ercDebt: ercAmount,
                ercDebtRate: ercDebtRate,
                zethYieldRate: zethYieldRate,
                flaggerId: 0,
                tokenId: tokenId,
                updatedAt: LibOrders.getOffsetTimeHours()
            });
            emit Events.CreateShortRecord(asset, shorter, id);
        } else {
            // All shortRecordIds used, combine into max shortRecordId
            id = Constants.SHORT_MAX_ID;
            fillShortRecord(
                asset,
                shorter,
                id,
                status,
                collateral,
                ercAmount,
                ercDebtRate,
                zethYieldRate
            );
        }
    }

    function transferShortRecord(
        address asset,
        address from,
        address to,
        uint40 tokenId,
        STypes.NFT memory nft
    ) internal {
        AppStorage storage s = appStorage();
        STypes.ShortRecord storage short = s.shortRecords[asset][from][nft.shortRecordId];
        if (short.status == SR.Cancelled) revert Errors.OriginalShortRecordCancelled();
        if (short.flaggerId != 0) revert Errors.CannotTransferFlaggedShort();

        deleteShortRecord(asset, from, nft.shortRecordId);

        uint8 id = createShortRecord(
            asset,
            to,
            SR.FullyFilled,
            short.collateral,
            short.ercDebt,
            short.ercDebtRate,
            short.zethYieldRate,
            tokenId
        );

        if (id == Constants.SHORT_MAX_ID) {
            revert Errors.ReceiverExceededShortRecordLimit();
        }

        s.nftMapping[tokenId].owner = to;
        s.nftMapping[tokenId].shortRecordId = id;
    }

    function fillShortRecord(
        address asset,
        address shorter,
        uint8 shortId,
        SR status,
        uint88 collateral,
        uint88 ercAmount,
        uint256 ercDebtRate,
        uint256 zethYieldRate
    ) internal {
        AppStorage storage s = appStorage();

        uint256 ercDebtSocialized = ercAmount.mul(ercDebtRate);
        uint256 yield = collateral.mul(zethYieldRate);

        STypes.ShortRecord storage short = s.shortRecords[asset][shorter][shortId];
        if (short.status == SR.Cancelled) {
            short.ercDebt = short.collateral = 0;
        }

        short.status = status;
        LibShortRecord.merge(
            short,
            ercAmount,
            ercDebtSocialized,
            collateral,
            yield,
            LibOrders.getOffsetTimeHours()
        );
    }

    function deleteShortRecord(address asset, address shorter, uint8 id) internal {
        AppStorage storage s = appStorage();

        STypes.ShortRecord storage shortRecord = s.shortRecords[asset][shorter][id];
        // Because of the onlyValidShortRecord modifier, only cancelShort can pass SR.Cancelled
        // Don't recycle shortRecord id 254 so it can be used for all overflow uint8 ids
        if (shortRecord.status != SR.PartialFill && id < Constants.SHORT_MAX_ID) {
            // remove the links of ID in the market
            // @dev (ID) is exiting, [ID] is inserted
            // BEFORE: PREV <-> (ID) <-> NEXT
            // AFTER : PREV <----------> NEXT
            s.shortRecords[asset][shorter][shortRecord.prevId].nextId = shortRecord.nextId;
            if (shortRecord.nextId != Constants.HEAD) {
                s.shortRecords[asset][shorter][shortRecord.nextId].prevId =
                    shortRecord.prevId;
            }
            // Make reuseable for future short records
            uint8 prevHEAD = s.shortRecords[asset][shorter][Constants.HEAD].prevId;
            s.shortRecords[asset][shorter][Constants.HEAD].prevId = id;
            // Move the cancelled ID behind HEAD to re-use it
            // note: C_IDs (cancelled ids) only need to point back (set prevId, can retain nextId)
            // BEFORE: .. C_ID2 <- C_ID1 <--------- HEAD <-> ... [ID]
            // AFTER1: .. C_ID2 <- C_ID1 <- [ID] <- HEAD <-> ...
            if (prevHEAD > Constants.HEAD) {
                shortRecord.prevId = prevHEAD;
            } else {
                // if this is the first ID cancelled
                // HEAD.prevId needs to be HEAD
                // and one of the cancelled id.prevID should point to HEAD
                // BEFORE: HEAD <--------- HEAD <-> ... [ID]
                // AFTER1: HEAD <- [ID] <- HEAD <-> ...
                shortRecord.prevId = Constants.HEAD;
            }

            //Event for delete SR is emitted here and not at the top level because
            //SR may be cancelled, but there might tied to an active short order
            //The code above is hit when that SR id is ready for reuse
            emit Events.DeleteShortRecord(asset, shorter, id);
        }

        shortRecord.status = SR.Cancelled;
    }

    function setShortRecordIds(address asset, address shorter)
        private
        returns (uint8 id, uint8 nextId)
    {
        AppStorage storage s = appStorage();

        STypes.ShortRecord storage guard = s.shortRecords[asset][shorter][Constants.HEAD];
        STypes.AssetUser storage AssetUser = s.assetUser[asset][shorter];
        // Initialize HEAD in case of first short createShortRecord
        if (AssetUser.shortRecordId == 0) {
            AssetUser.shortRecordId = Constants.SHORT_STARTING_ID;
            guard.prevId = Constants.HEAD;
            guard.nextId = Constants.HEAD;
        }
        // BEFORE: HEAD <-> .. <-> PREV <--------------> NEXT
        // AFTER1: HEAD <-> .. <-> PREV <-> (NEW ID) <-> NEXT
        // place created short next to HEAD
        nextId = guard.nextId;
        uint8 canceledId = guard.prevId;
        // @dev (ID) is exiting, [ID] is inserted
        // in this case, the protocol re-uses (ID) and moves it to [ID]
        // check if a previously closed short exists
        if (canceledId > Constants.HEAD) {
            // BEFORE: CancelledID <- (ID) <- HEAD <-> .. <-> PREV <----------> NEXT
            // AFTER1: CancelledID <--------- HEAD <-> .. <-> PREV <-> [ID] <-> NEXT
            uint8 prevCanceledId = s.shortRecords[asset][shorter][canceledId].prevId;
            if (prevCanceledId > Constants.HEAD) {
                guard.prevId = prevCanceledId;
            } else {
                // BEFORE: HEAD <- (ID) <- HEAD <-> .. <-> PREV <----------> NEXT
                // AFTER1: HEAD <--------- HEAD <-> .. <-> PREV <-> [ID] <-> NEXT
                guard.prevId = Constants.HEAD;
            }
            // re-use the previous order's id
            id = canceledId;
        } else {
            // BEFORE: HEAD <-> .. <-> PREV <--------------> NEXT
            // AFTER1: HEAD <-> .. <-> PREV <-> (NEW ID) <-> NEXT
            // otherwise just increment to a new short record id
            // and the short record grows in height/size
            id = AssetUser.shortRecordId;
            // Avoids overflow revert, prevents DOS on uint8
            if (id < type(uint8).max) {
                AssetUser.shortRecordId += 1;
            } else {
                // If max id reached, match into max shortRecordId
                return (id, nextId);
            }
        }

        if (nextId > Constants.HEAD) {
            s.shortRecords[asset][shorter][nextId].prevId = id;
        }
        guard.nextId = id;
    }

    function updateErcDebt(address asset, address shorter, uint8 shortId) internal {
        AppStorage storage s = appStorage();

        STypes.ShortRecord storage short = s.shortRecords[asset][shorter][shortId];

        // Distribute ercDebt
        uint64 ercDebtRate = s.asset[asset].ercDebtRate;
        uint88 ercDebt = short.ercDebt.mulU88(ercDebtRate - short.ercDebtRate);

        if (ercDebt > 0) {
            short.ercDebt += ercDebt;
            short.ercDebtRate = ercDebtRate;
        }
    }

    function updateErcDebt(STypes.ShortRecord storage short, address asset) internal {
        AppStorage storage s = appStorage();

        // Distribute ercDebt
        uint64 ercDebtRate = s.asset[asset].ercDebtRate;
        uint88 ercDebt = short.ercDebt.mulU88(ercDebtRate - short.ercDebtRate);

        if (ercDebt > 0) {
            short.ercDebt += ercDebt;
            short.ercDebtRate = ercDebtRate;
        }
    }

    function merge(
        STypes.ShortRecord storage short,
        uint88 ercDebt,
        uint256 ercDebtSocialized,
        uint88 collateral,
        uint256 yield,
        uint24 creationTime
    ) internal {
        // Resolve ercDebt
        ercDebtSocialized += short.ercDebt.mul(short.ercDebtRate);
        short.ercDebt += ercDebt;
        short.ercDebtRate = ercDebtSocialized.divU64(short.ercDebt);
        // Resolve zethCollateral
        yield += short.collateral.mul(short.zethYieldRate);
        short.collateral += collateral;
        short.zethYieldRate = yield.divU80(short.collateral);
        // Assign updatedAt
        short.updatedAt = creationTime;
    }

    function disburseCollateral(
        address asset,
        address shorter,
        uint88 collateral,
        uint256 zethYieldRate,
        uint24 updatedAt
    ) internal {
        AppStorage storage s = appStorage();

        STypes.Asset storage Asset = s.asset[asset];
        uint256 vault = Asset.vault;
        STypes.Vault storage Vault = s.vault[vault];

        Vault.zethCollateral -= collateral;
        Asset.zethCollateral -= collateral;
        // Distribute yield
        uint88 yield = collateral.mulU88(Vault.zethYieldRate - zethYieldRate);
        if (yield > 0) {
            /*
            @dev If somebody exits a short, gets margin called, decreases their collateral before YIELD_DELAY_HOURS duration is up,
            they lose their yield to the TAPP
            */
            bool isNotRecentlyModified =
                LibOrders.getOffsetTimeHours() - updatedAt > Constants.YIELD_DELAY_HOURS;
            if (isNotRecentlyModified) {
                s.vaultUser[vault][shorter].ethEscrowed += yield;
            } else {
                s.vaultUser[vault][address(this)].ethEscrowed += yield;
            }
        }
    }

    function burnNFT(uint256 tokenId) internal {
        //@dev No need to check downcast tokenId because it is handled in function that calls burnNFT
        AppStorage storage s = appStorage();
        STypes.NFT storage nft = s.nftMapping[tokenId];
        if (nft.owner == address(0)) revert Errors.NotMinted();
        address asset = s.assetMapping[nft.assetId];
        STypes.ShortRecord storage short =
            s.shortRecords[asset][nft.owner][nft.shortRecordId];
        delete s.nftMapping[tokenId];
        delete s.getApproved[tokenId];
        delete short.tokenId;
        emit Events.Transfer(nft.owner, address(0), tokenId);
    }

    function setFlagger(
        STypes.ShortRecord storage short,
        address cusd,
        uint16 flaggerHint
    ) internal {
        AppStorage storage s = appStorage();
        STypes.AssetUser storage flagStorage = s.assetUser[cusd][msg.sender];

        //@dev Whenever a new flagger flags, use the flaggerIdCounter.
        if (flagStorage.g_flaggerId == 0) {
            address flaggerToReplace = s.flagMapping[flaggerHint];

            uint256 timeDiff = flaggerToReplace != address(0)
                ? LibOrders.getOffsetTimeHours()
                    - s.assetUser[cusd][flaggerToReplace].g_updatedAt
                : 0;
            //@dev re-use an inactive flaggerId
            if (timeDiff > LibAsset.firstLiquidationTime(cusd)) {
                delete s.assetUser[cusd][flaggerToReplace].g_flaggerId;
                short.flaggerId = flagStorage.g_flaggerId = flaggerHint;
            } else if (s.flaggerIdCounter < type(uint16).max) {
                //@dev generate brand new flaggerId
                short.flaggerId = flagStorage.g_flaggerId = s.flaggerIdCounter;
                s.flaggerIdCounter++;
            } else {
                revert Errors.InvalidFlaggerHint();
            }
            s.flagMapping[short.flaggerId] = msg.sender;
        } else {
            //@dev re-use flaggerId if flagger has an existing one
            short.flaggerId = flagStorage.g_flaggerId;
        }
        short.updatedAt = flagStorage.g_updatedAt = LibOrders.getOffsetTimeHours();
    }

    //@dev reset flag info if new cratio is above primaryLiquidationCR
    function maybeResetFlag(STypes.ShortRecord storage short, address asset) internal {
        if (short.flaggerId != 0) {
            if (
                LibShortRecord.getCollateralRatio(short, asset)
                    >= LibAsset.primaryLiquidationCR(asset)
            ) {
                LibShortRecord.resetFlag(short);
            }
        }
    }

    function resetFlag(STypes.ShortRecord storage shortRecord) internal {
        delete shortRecord.flaggerId;
        shortRecord.updatedAt = LibOrders.getOffsetTimeHours();
    }
}