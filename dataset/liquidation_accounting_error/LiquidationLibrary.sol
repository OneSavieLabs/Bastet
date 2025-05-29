// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;
import "./Interfaces/ICdpManagerData.sol";
import "./Interfaces/ICollSurplusPool.sol";
import "./Interfaces/IEBTCToken.sol";
import "./Interfaces/ISortedCdps.sol";
import "./Dependencies/ICollateralTokenOracle.sol";
import "./CdpManagerStorage.sol";

/// @title LiquidationLibrary mainly provide necessary logic to fulfill liquidation for eBTC Cdps.
/// @dev This contract shares same base and storage layout with CdpManager and is the delegatecall destination from CdpManager
contract LiquidationLibrary is CdpManagerStorage {
    constructor(
        address _borrowerOperationsAddress,
        address _collSurplusPool,
        address _ebtcToken,
        address _sortedCdps,
        address _activePool,
        address _priceFeed,
        address _collateral
    )
        CdpManagerStorage(
            address(0),
            address(0),
            _borrowerOperationsAddress,
            _collSurplusPool,
            _ebtcToken,
            _sortedCdps,
            _activePool,
            _priceFeed,
            _collateral
        )
    {}

    /// @notice Fully liquidate a single Cdp by ID. Cdp must meet the criteria for liquidation at the time of execution.
    /// @notice callable by anyone, attempts to liquidate the CdpId. Executes successfully if Cdp meets the conditions for liquidation (e.g. in Normal Mode, it liquidates if the Cdp's ICR < the system MCR).
    /// @dev forwards msg.data directly to the liquidation library using OZ proxy core delegation function
    /// @param _cdpId ID of the Cdp to liquidate.
    function liquidate(bytes32 _cdpId) external nonReentrantSelfAndBOps {
        _liquidateIndividualCdpSetup(_cdpId, 0, _cdpId, _cdpId);
    }

    /// @notice Partially liquidate a single Cdp.
    /// @dev forwards msg.data directly to the liquidation library using OZ proxy core delegation function
    /// @param _cdpId ID of the Cdp to partially liquidate.
    /// @param _partialAmount Amount to partially liquidate.
    /// @param _upperPartialHint Upper hint for reinsertion of the Cdp into the linked list.
    /// @param _lowerPartialHint Lower hint for reinsertion of the Cdp into the linked list.
    function partiallyLiquidate(
        bytes32 _cdpId,
        uint256 _partialAmount,
        bytes32 _upperPartialHint,
        bytes32 _lowerPartialHint
    ) external nonReentrantSelfAndBOps {
        require(_partialAmount != 0, "LiquidationLibrary: use `liquidate` for 100%");
        _liquidateIndividualCdpSetup(_cdpId, _partialAmount, _upperPartialHint, _lowerPartialHint);
    }

    // Single CDP liquidation function.
    function _liquidateIndividualCdpSetup(
        bytes32 _cdpId,
        uint256 _partialAmount,
        bytes32 _upperPartialHint,
        bytes32 _lowerPartialHint
    ) internal {
        _requireCdpIsActive(_cdpId);

        _syncAccounting(_cdpId);

        uint256 _price = priceFeed.fetchPrice();

        // prepare local variables
        uint256 _ICR = getCachedICR(_cdpId, _price); // @audit syncAccounting already called, guarenteed to be synced
        (uint256 _TCR, uint256 systemColl, uint256 systemDebt) = _getTCRWithSystemDebtAndCollShares(
            _price
        );

        // If CDP is above MCR
        if (_ICR >= MCR) {
            // We must be in RM
            require(
                _checkICRAgainstLiqThreshold(_ICR, _TCR),
                "LiquidationLibrary: ICR is not below liquidation threshold in current mode"
            );

            // == Grace Period == //
            uint128 cachedLastGracePeriodStartTimestamp = lastGracePeriodStartTimestamp;
            require(
                cachedLastGracePeriodStartTimestamp != UNSET_TIMESTAMP,
                "LiquidationLibrary: Recovery Mode grace period not started"
            );
            require(
                block.timestamp >
                    cachedLastGracePeriodStartTimestamp + recoveryModeGracePeriodDuration,
                "LiquidationLibrary: Recovery mode grace period still in effect"
            );
        } // Implicit Else Case, Implies ICR < MRC, meaning the CDP is liquidatable

        bool _recoveryModeAtStart = _TCR < CCR ? true : false;
        LiquidationLocals memory _liqState = LiquidationLocals(
            _cdpId,
            _partialAmount,
            _price,
            _ICR,
            _upperPartialHint,
            _lowerPartialHint,
            (_recoveryModeAtStart),
            _TCR,
            0,
            0,
            0,
            0,
            0
        );

        LiquidationRecoveryModeLocals memory _rs = LiquidationRecoveryModeLocals(
            systemDebt,
            systemColl,
            0,
            0,
            0,
            _cdpId,
            _price,
            _ICR,
            0,
            0
        );

        _liquidateIndividualCdpSetupCDP(_liqState, _rs);
    }

    // liquidate given CDP by repaying debt in full or partially if its ICR is below MCR or TCR in recovery mode.
    // For partial liquidation, caller should use HintHelper smart contract to get correct hints for reinsertion into sorted CDP list
    function _liquidateIndividualCdpSetupCDP(
        LiquidationLocals memory _liqState,
        LiquidationRecoveryModeLocals memory _recoveryState
    ) internal {
        LiquidationValues memory liquidationValues;

        uint256 startingSystemDebt = _recoveryState.entireSystemDebt;
        uint256 startingSystemColl = _recoveryState.entireSystemColl;

        if (_liqState.partialAmount == 0) {
            (
                liquidationValues.debtToBurn,
                liquidationValues.totalCollToSendToLiquidator,
                liquidationValues.debtToRedistribute,
                liquidationValues.liquidatorCollSharesReward,
                liquidationValues.collSurplus
            ) = _liquidateCdpInGivenMode(_liqState, _recoveryState);
        } else {
            (
                liquidationValues.debtToBurn,
                liquidationValues.totalCollToSendToLiquidator
            ) = _liquidateCDPPartially(_liqState);
            if (
                liquidationValues.totalCollToSendToLiquidator == 0 &&
                liquidationValues.debtToBurn == 0
            ) {
                // retry with fully liquidation
                (
                    liquidationValues.debtToBurn,
                    liquidationValues.totalCollToSendToLiquidator,
                    liquidationValues.debtToRedistribute,
                    liquidationValues.liquidatorCollSharesReward,
                    liquidationValues.collSurplus
                ) = _liquidateCdpInGivenMode(_liqState, _recoveryState);
            }
        }

        _finalizeLiquidation(
            liquidationValues.debtToBurn,
            liquidationValues.totalCollToSendToLiquidator,
            liquidationValues.debtToRedistribute,
            liquidationValues.liquidatorCollSharesReward,
            liquidationValues.collSurplus,
            startingSystemColl,
            startingSystemDebt,
            _liqState.price
        );
    }

    // liquidate (and close) the CDP from an external liquidator
    // this function would return the liquidated debt and collateral of the given CDP
    function _liquidateCdpInGivenMode(
        LiquidationLocals memory _liqState,
        LiquidationRecoveryModeLocals memory _recoveryState
    ) private returns (uint256, uint256, uint256, uint256, uint256) {
        if (_liqState.recoveryModeAtStart) {
            LiquidationRecoveryModeLocals
                memory _outputState = _liquidateIndividualCdpSetupCDPInRecoveryMode(_recoveryState);

            // housekeeping leftover collateral for liquidated CDP
            if (_outputState.totalSurplusCollShares > 0) {
                activePool.transferSystemCollShares(
                    address(collSurplusPool),
                    _outputState.totalSurplusCollShares
                );
            }

            return (
                _outputState.totalDebtToBurn,
                _outputState.totalCollSharesToSend,
                _outputState.totalDebtToRedistribute,
                _outputState.totalLiquidatorRewardCollShares,
                _outputState.totalSurplusCollShares
            );
        } else {
            LiquidationLocals memory _outputState = _liquidateIndividualCdpSetupCDPInNormalMode(
                _liqState
            );
            return (
                _outputState.totalDebtToBurn,
                _outputState.totalCollSharesToSend,
                _outputState.totalDebtToRedistribute,
                _outputState.totalLiquidatorRewardCollShares,
                _outputState.totalSurplusCollShares
            );
        }
    }

    function _liquidateIndividualCdpSetupCDPInNormalMode(
        LiquidationLocals memory _liqState
    ) private returns (LiquidationLocals memory) {
        // liquidate entire debt
        (
            uint256 _totalDebtToBurn,
            uint256 _totalColToSend,
            uint256 _liquidatorReward
        ) = _closeCdpByLiquidation(_liqState.cdpId);
        uint256 _cappedColPortion;
        uint256 _collSurplus;
        uint256 _debtToRedistribute;
        address _borrower = sortedCdps.getOwnerAddress(_liqState.cdpId);

        // I don't see an issue emitting the CdpUpdated() event up here and avoiding this extra cache, any objections?
        emit CdpUpdated(
            _liqState.cdpId,
            _borrower,
            msg.sender,
            _totalDebtToBurn,
            _totalColToSend,
            0,
            0,
            0,
            CdpOperation.liquidateInNormalMode
        );

        {
            (
                _cappedColPortion,
                _collSurplus,
                _debtToRedistribute
            ) = _calculateFullLiquidationSurplusAndCap(
                _liqState.ICR,
                _liqState.price,
                _totalDebtToBurn,
                _totalColToSend
            );
            if (_collSurplus > 0) {
                // due to division precision loss, should be zero surplus in normal mode
                _cappedColPortion = _cappedColPortion + _collSurplus;
                _collSurplus = 0;
            }
            if (_debtToRedistribute > 0) {
                _totalDebtToBurn = _totalDebtToBurn - _debtToRedistribute;
            }
        }
        _liqState.totalDebtToBurn = _liqState.totalDebtToBurn + _totalDebtToBurn;
        _liqState.totalCollSharesToSend = _liqState.totalCollSharesToSend + _cappedColPortion;
        _liqState.totalDebtToRedistribute = _liqState.totalDebtToRedistribute + _debtToRedistribute;
        _liqState.totalLiquidatorRewardCollShares =
            _liqState.totalLiquidatorRewardCollShares +
            _liquidatorReward;

        // Emit events
        uint _debtToColl = (_totalDebtToBurn * DECIMAL_PRECISION) / _liqState.price;
        uint _cappedColl = collateral.getPooledEthByShares(_cappedColPortion + _liquidatorReward);

        emit CdpLiquidated(
            _liqState.cdpId,
            _borrower,
            _totalDebtToBurn,
            // please note this is the collateral share of the liquidated CDP
            _cappedColPortion,
            CdpOperation.liquidateInNormalMode,
            msg.sender,
            _cappedColl > _debtToColl ? (_cappedColl - _debtToColl) : 0
        );

        return _liqState;
    }

    function _liquidateIndividualCdpSetupCDPInRecoveryMode(
        LiquidationRecoveryModeLocals memory _recoveryState
    ) private returns (LiquidationRecoveryModeLocals memory) {
        // liquidate entire debt
        (
            uint256 _totalDebtToBurn,
            uint256 _totalColToSend,
            uint256 _liquidatorReward
        ) = _closeCdpByLiquidation(_recoveryState.cdpId);

        // cap the liquidated collateral if required
        uint256 _cappedColPortion;
        uint256 _collSurplus;
        uint256 _debtToRedistribute;
        address _borrower = sortedCdps.getOwnerAddress(_recoveryState.cdpId);

        // I don't see an issue emitting the CdpUpdated() event up here and avoiding an extra cache of the values, any objections?
        emit CdpUpdated(
            _recoveryState.cdpId,
            _borrower,
            msg.sender,
            _totalDebtToBurn,
            _totalColToSend,
            0,
            0,
            0,
            CdpOperation.liquidateInRecoveryMode
        );

        // avoid stack too deep
        {
            (
                _cappedColPortion,
                _collSurplus,
                _debtToRedistribute
            ) = _calculateFullLiquidationSurplusAndCap(
                _recoveryState.ICR,
                _recoveryState.price,
                _totalDebtToBurn,
                _totalColToSend
            );
            if (_collSurplus > 0) {
                collSurplusPool.increaseSurplusCollShares(_borrower, _collSurplus);
                _recoveryState.totalSurplusCollShares =
                    _recoveryState.totalSurplusCollShares +
                    _collSurplus;
            }
            if (_debtToRedistribute > 0) {
                _totalDebtToBurn = _totalDebtToBurn - _debtToRedistribute;
            }
        }
        _recoveryState.totalDebtToBurn = _recoveryState.totalDebtToBurn + _totalDebtToBurn;
        _recoveryState.totalCollSharesToSend =
            _recoveryState.totalCollSharesToSend +
            _cappedColPortion;
        _recoveryState.totalDebtToRedistribute =
            _recoveryState.totalDebtToRedistribute +
            _debtToRedistribute;
        _recoveryState.totalLiquidatorRewardCollShares =
            _recoveryState.totalLiquidatorRewardCollShares +
            _liquidatorReward;

        // check if system back to normal mode
        _recoveryState.entireSystemDebt = _recoveryState.entireSystemDebt > _totalDebtToBurn
            ? _recoveryState.entireSystemDebt - _totalDebtToBurn
            : 0;
        _recoveryState.entireSystemColl = _recoveryState.entireSystemColl > _totalColToSend
            ? _recoveryState.entireSystemColl - _totalColToSend
            : 0;

        uint _debtToColl = (_totalDebtToBurn * DECIMAL_PRECISION) / _recoveryState.price;
        uint _cappedColl = collateral.getPooledEthByShares(_cappedColPortion + _liquidatorReward);
        emit CdpLiquidated(
            _recoveryState.cdpId,
            _borrower,
            _totalDebtToBurn,
            // please note this is the collateral share of the liquidated CDP
            _cappedColPortion,
            CdpOperation.liquidateInRecoveryMode,
            msg.sender,
            _cappedColl > _debtToColl ? (_cappedColl - _debtToColl) : 0
        );

        return _recoveryState;
    }

    // liquidate (and close) the CDP from an external liquidator
    // this function would return the liquidated debt and collateral of the given CDP
    // without emmiting events
    function _closeCdpByLiquidation(bytes32 _cdpId) private returns (uint256, uint256, uint256) {
        // calculate entire debt to repay
        (uint256 entireDebt, uint256 entireColl) = getSyncedDebtAndCollShares(_cdpId);

        // housekeeping after liquidation by closing the CDP
        uint256 _liquidatorReward = Cdps[_cdpId].liquidatorRewardShares;
        _closeCdp(_cdpId, Status.closedByLiquidation);

        return (entireDebt, entireColl, _liquidatorReward);
    }

    // Liquidate partially the CDP by an external liquidator
    // This function would return the liquidated debt and collateral of the given CDP
    function _liquidateCDPPartially(
        LiquidationLocals memory _partialState
    ) private returns (uint256, uint256) {
        bytes32 _cdpId = _partialState.cdpId;
        uint256 _partialDebt = _partialState.partialAmount;

        // calculate entire debt to repay
        CdpDebtAndCollShares memory _debtAndColl = _getSyncedDebtAndCollShares(_cdpId);
        _requirePartialLiqDebtSize(_partialDebt, _debtAndColl.debt, _partialState.price);
        uint256 newDebt = _debtAndColl.debt - _partialDebt;

        // credit to https://arxiv.org/pdf/2212.07306.pdf for details
        (uint256 _partialColl, uint256 newColl, ) = _calculatePartialLiquidationSurplusAndCap(
            _partialState.ICR,
            _partialState.price,
            _partialDebt,
            _debtAndColl.collShares
        );

        // early return: if new collateral is zero, we have a full liqudiation
        if (newColl == 0) {
            return (0, 0);
        }

        // If we have coll remaining, it must meet minimum CDP size requirements
        _requirePartialLiqCollSize(collateral.getPooledEthByShares(newColl));

        // updating the CDP accounting for partial liquidation
        _partiallyReduceCdpDebt(_cdpId, _partialDebt, _partialColl);

        // reInsert into sorted CDP list after partial liquidation
        {
            _reInsertPartialLiquidation(
                _partialState,
                EbtcMath._computeNominalCR(newColl, newDebt),
                _debtAndColl.debt,
                _debtAndColl.collShares
            );
            uint _debtToColl = (_partialDebt * DECIMAL_PRECISION) / _partialState.price;
            uint _cappedColl = collateral.getPooledEthByShares(_partialColl);
            emit CdpPartiallyLiquidated(
                _cdpId,
                sortedCdps.getOwnerAddress(_cdpId),
                _partialDebt,
                _partialColl,
                CdpOperation.partiallyLiquidate,
                msg.sender,
                _cappedColl > _debtToColl ? (_cappedColl - _debtToColl) : 0
            );
        }
        return (_partialDebt, _partialColl);
    }

    function _partiallyReduceCdpDebt(
        bytes32 _cdpId,
        uint256 _partialDebt,
        uint256 _partialColl
    ) internal {
        Cdp storage _cdp = Cdps[_cdpId];

        uint256 _coll = _cdp.coll;
        uint256 _debt = _cdp.debt;

        _cdp.coll = _coll - _partialColl;
        _cdp.debt = _debt - _partialDebt;
        _updateStakeAndTotalStakes(_cdpId);
    }

    // Re-Insertion into SortedCdp list after partial liquidation
    function _reInsertPartialLiquidation(
        LiquidationLocals memory _partialState,
        uint256 _newNICR,
        uint256 _oldDebt,
        uint256 _oldColl
    ) internal {
        bytes32 _cdpId = _partialState.cdpId;

        // ensure new ICR does NOT decrease due to partial liquidation
        // if original ICR is above LICR
        if (_partialState.ICR > LICR) {
            require(
                getCachedICR(_cdpId, _partialState.price) >= _partialState.ICR,
                "LiquidationLibrary: !_newICR>=_ICR"
            );
        }

        // reInsert into sorted CDP list
        sortedCdps.reInsert(
            _cdpId,
            _newNICR,
            _partialState.upperPartialHint,
            _partialState.lowerPartialHint
        );
        emit CdpUpdated(
            _cdpId,
            sortedCdps.getOwnerAddress(_cdpId),
            msg.sender,
            _oldDebt,
            _oldColl,
            Cdps[_cdpId].debt,
            Cdps[_cdpId].coll,
            Cdps[_cdpId].stake,
            CdpOperation.partiallyLiquidate
        );
    }

    function _finalizeLiquidation(
        uint256 totalDebtToBurn,
        uint256 totalCollSharesToSend,
        uint256 totalDebtToRedistribute,
        uint256 totalLiquidatorRewardCollShares,
        uint256 totalSurplusCollShares,
        uint256 systemInitialCollShares,
        uint256 systemInitialDebt,
        uint256 price
    ) internal {
        // update the staking and collateral snapshots
        _updateSystemSnapshotsExcludeCollRemainder(totalCollSharesToSend);

        emit Liquidation(totalDebtToBurn, totalCollSharesToSend, totalLiquidatorRewardCollShares);

        _syncGracePeriodForGivenValues(
            systemInitialCollShares - totalCollSharesToSend - totalSurplusCollShares,
            systemInitialDebt - totalDebtToBurn,
            price
        );

        // redistribute debt if any
        if (totalDebtToRedistribute > 0) {
            _redistributeDebt(totalDebtToRedistribute);
        }

        // burn the debt from liquidator
        ebtcToken.burn(msg.sender, totalDebtToBurn);

        // offset debt from Active Pool
        activePool.decreaseSystemDebt(totalDebtToBurn);

        // CEI: ensure sending back collateral to liquidator is last thing to do
        activePool.transferSystemCollSharesAndLiquidatorReward(
            msg.sender,
            totalCollSharesToSend,
            totalLiquidatorRewardCollShares
        );
    }

    // Partial Liquidation Cap Logic
    function _calculatePartialLiquidationSurplusAndCap(
        uint256 _ICR,
        uint256 _price,
        uint256 _totalDebtToBurn,
        uint256 _totalColToSend
    ) private view returns (uint256 toLiquidator, uint256 collSurplus, uint256 debtToRedistribute) {
        uint256 _incentiveColl;

        // CLAMP
        if (_ICR > LICR) {
            // Cap at 10%
            _incentiveColl = (_totalDebtToBurn * (_ICR > MCR ? MCR : _ICR)) / _price;
        } else {
            // Min 103%
            _incentiveColl = (_totalDebtToBurn * LICR) / _price;
        }

        toLiquidator = collateral.getSharesByPooledEth(_incentiveColl);

        /// @audit MUST be like so, else we have debt redistribution, which we assume cannot happen in partial
        assert(toLiquidator < _totalColToSend); // Assert is correct here for Echidna

        /// Because of above we can subtract
        collSurplus = _totalColToSend - toLiquidator; // Can use unchecked but w/e
    }

    function _calculateFullLiquidationSurplusAndCap(
        uint256 _ICR,
        uint256 _price,
        uint256 _totalDebtToBurn,
        uint256 _totalColToSend
    ) private view returns (uint256 toLiquidator, uint256 collSurplus, uint256 debtToRedistribute) {
        uint256 _incentiveColl;

        if (_ICR > LICR) {
            _incentiveColl = (_totalDebtToBurn * (_ICR > MCR ? MCR : _ICR)) / _price;

            // Convert back to shares
            toLiquidator = collateral.getSharesByPooledEth(_incentiveColl);
        } else {
            // for full liquidation, there would be some bad debt to redistribute
            _incentiveColl = collateral.getPooledEthByShares(_totalColToSend);

            // Since it's full and there's bad debt we use spot conversion to
            // Determine the amount of debt that willl be repaid after adding the LICR discount
            // Basically this is buying underwater Coll
            // By repaying debt at 3% discount
            // Can there be a rounding error where the _debtToRepay > debtToBurn?
            uint256 _debtToRepay = (_incentiveColl * _price) / LICR;

            debtToRedistribute = _debtToRepay < _totalDebtToBurn
                ? _totalDebtToBurn - _debtToRepay //  Bad Debt (to be redistributed) is (CdpDebt - Repaid)
                : 0; // Else 0 (note we may underpay per the comment above, althought that may be imaginary)

            // now CDP owner should have zero surplus to claim
            toLiquidator = _totalColToSend;
        }

        toLiquidator = toLiquidator < _totalColToSend ? toLiquidator : _totalColToSend;
        collSurplus = (toLiquidator == _totalColToSend) ? 0 : _totalColToSend - toLiquidator;
    }

    // --- Batch liquidation functions ---

    function _getLiquidationValuesNormalMode(
        uint256 _price,
        uint256 _TCR,
        LocalVariables_LiquidationSequence memory vars,
        LiquidationValues memory singleLiquidation
    ) internal {
        LiquidationLocals memory _liqState = LiquidationLocals(
            vars.cdpId,
            0,
            _price,
            vars.ICR,
            vars.cdpId,
            vars.cdpId,
            (false),
            _TCR,
            0,
            0,
            0,
            0,
            0
        );

        LiquidationLocals memory _outputState = _liquidateIndividualCdpSetupCDPInNormalMode(
            _liqState
        );

        singleLiquidation.entireCdpDebt = _outputState.totalDebtToBurn;
        singleLiquidation.debtToBurn = _outputState.totalDebtToBurn;
        singleLiquidation.totalCollToSendToLiquidator = _outputState.totalCollSharesToSend;
        singleLiquidation.collSurplus = _outputState.totalSurplusCollShares;
        singleLiquidation.debtToRedistribute = _outputState.totalDebtToRedistribute;
        singleLiquidation.liquidatorCollSharesReward = _outputState.totalLiquidatorRewardCollShares;
    }

    function _getLiquidationValuesRecoveryMode(
        uint256 _price,
        uint256 _systemDebt,
        uint256 _systemCollShares,
        LocalVariables_LiquidationSequence memory vars,
        LiquidationValues memory singleLiquidation
    ) internal {
        LiquidationRecoveryModeLocals memory _recState = LiquidationRecoveryModeLocals(
            _systemDebt,
            _systemCollShares,
            0,
            0,
            0,
            vars.cdpId,
            _price,
            vars.ICR,
            0,
            0
        );

        LiquidationRecoveryModeLocals
            memory _outputState = _liquidateIndividualCdpSetupCDPInRecoveryMode(_recState);

        singleLiquidation.entireCdpDebt = _outputState.totalDebtToBurn;
        singleLiquidation.debtToBurn = _outputState.totalDebtToBurn;
        singleLiquidation.totalCollToSendToLiquidator = _outputState.totalCollSharesToSend;
        singleLiquidation.collSurplus = _outputState.totalSurplusCollShares;
        singleLiquidation.debtToRedistribute = _outputState.totalDebtToRedistribute;
        singleLiquidation.liquidatorCollSharesReward = _outputState.totalLiquidatorRewardCollShares;
    }

    /// @notice Attempt to liquidate a custom list of Cdps provided by the caller
    /// @notice Callable by anyone, accepts a custom list of Cdps addresses as an argument.
    /// @notice Steps through the provided list and attempts to liquidate every Cdp, until it reaches the end or it runs out of gas.
    /// @notice A Cdp is liquidated only if it meets the conditions for liquidation.
    /// @dev forwards msg.data directly to the liquidation library using OZ proxy core delegation function
    /// @param _cdpArray Array of Cdps to liquidate.
    function batchLiquidateCdps(bytes32[] memory _cdpArray) external nonReentrantSelfAndBOps {
        require(
            _cdpArray.length != 0,
            "LiquidationLibrary: Calldata address array must not be empty"
        );

        LocalVariables_OuterLiquidationFunction memory vars;
        LiquidationTotals memory totals;

        // taking fee to avoid accounted for the calculation of the TCR
        _syncGlobalAccounting();

        vars.price = priceFeed.fetchPrice();
        (uint256 _TCR, uint256 systemColl, uint256 systemDebt) = _getTCRWithSystemDebtAndCollShares(
            vars.price
        );
        vars.recoveryModeAtStart = _TCR < CCR ? true : false;

        // Perform the appropriate batch liquidation - tally values and obtain their totals.
        if (vars.recoveryModeAtStart) {
            totals = _getTotalFromBatchLiquidate_RecoveryMode(
                vars.price,
                systemColl,
                systemDebt,
                _cdpArray
            );
        } else {
            //  if !vars.recoveryModeAtStart
            totals = _getTotalsFromBatchLiquidate_NormalMode(vars.price, _TCR, _cdpArray);
        }

        require(totals.totalDebtInSequence > 0, "LiquidationLibrary: nothing to liquidate");

        // housekeeping leftover collateral for liquidated CDPs
        if (totals.totalCollSurplus > 0) {
            activePool.transferSystemCollShares(address(collSurplusPool), totals.totalCollSurplus);
        }

        _finalizeLiquidation(
            totals.totalDebtToBurn,
            totals.totalCollToSendToLiquidator,
            totals.totalDebtToRedistribute,
            totals.totalCollReward,
            totals.totalCollSurplus,
            systemColl,
            systemDebt,
            vars.price
        );
    }

    /*
     * This function is used when the batch liquidation starts during Recovery Mode. However, it
     * handle the case where the system *leaves* Recovery Mode, part way through the liquidation processing
     */
    function _getTotalFromBatchLiquidate_RecoveryMode(
        uint256 _price,
        uint256 _systemCollShares,
        uint256 _systemDebt,
        bytes32[] memory _cdpArray
    ) internal returns (LiquidationTotals memory totals) {
        LocalVariables_LiquidationSequence memory vars;
        LiquidationValues memory singleLiquidation;

        vars.backToNormalMode = false;
        vars.entireSystemDebt = _systemDebt;
        vars.entireSystemColl = _systemCollShares;
        uint256 _TCR = _computeTCRWithGivenSystemValues(
            vars.entireSystemColl,
            vars.entireSystemDebt,
            _price
        );
        uint256 _cnt = _cdpArray.length;
        bool[] memory _liqFlags = new bool[](_cnt);
        uint256 _start;
        for (vars.i = _start; ; ) {
            vars.cdpId = _cdpArray[vars.i];
            // only for active cdps
            if (vars.cdpId != bytes32(0) && Cdps[vars.cdpId].status == Status.active) {
                vars.ICR = getSyncedICR(vars.cdpId, _price);

                if (
                    !vars.backToNormalMode &&
                    (_checkICRAgainstMCR(vars.ICR) || canLiquidateRecoveryMode(vars.ICR, _TCR))
                ) {
                    vars.price = _price;
                    _syncAccounting(vars.cdpId);
                    _getLiquidationValuesRecoveryMode(
                        _price,
                        vars.entireSystemDebt,
                        vars.entireSystemColl,
                        vars,
                        singleLiquidation
                    );

                    // Update aggregate trackers
                    vars.entireSystemDebt = vars.entireSystemDebt - singleLiquidation.debtToBurn;
                    vars.entireSystemColl =
                        vars.entireSystemColl -
                        singleLiquidation.totalCollToSendToLiquidator -
                        singleLiquidation.collSurplus;

                    // Add liquidation values to their respective running totals
                    totals = _addLiquidationValuesToTotals(totals, singleLiquidation);

                    _TCR = _computeTCRWithGivenSystemValues(
                        vars.entireSystemColl,
                        vars.entireSystemDebt,
                        _price
                    );
                    vars.backToNormalMode = _TCR < CCR ? false : true;
                    _liqFlags[vars.i] = true;
                } else if (vars.backToNormalMode && _checkICRAgainstMCR(vars.ICR)) {
                    _syncAccounting(vars.cdpId);
                    _getLiquidationValuesNormalMode(_price, _TCR, vars, singleLiquidation);

                    // Add liquidation values to their respective running totals
                    totals = _addLiquidationValuesToTotals(totals, singleLiquidation);
                    _liqFlags[vars.i] = true;
                }
                // In Normal Mode skip cdps with ICR >= MCR
            }
            ++vars.i;
            if (vars.i == _cnt) {
                break;
            }
        }
    }

    function _getTotalsFromBatchLiquidate_NormalMode(
        uint256 _price,
        uint256 _TCR,
        bytes32[] memory _cdpArray
    ) internal returns (LiquidationTotals memory totals) {
        LocalVariables_LiquidationSequence memory vars;
        LiquidationValues memory singleLiquidation;
        uint256 _cnt = _cdpArray.length;
        uint256 _start;
        for (vars.i = _start; ; ) {
            vars.cdpId = _cdpArray[vars.i];
            // only for active cdps
            if (vars.cdpId != bytes32(0) && Cdps[vars.cdpId].status == Status.active) {
                vars.ICR = getSyncedICR(vars.cdpId, _price);

                if (_checkICRAgainstMCR(vars.ICR)) {
                    _syncAccounting(vars.cdpId);
                    _getLiquidationValuesNormalMode(_price, _TCR, vars, singleLiquidation);

                    // Add liquidation values to their respective running totals
                    totals = _addLiquidationValuesToTotals(totals, singleLiquidation);
                }
            }
            ++vars.i;
            if (vars.i == _cnt) {
                break;
            }
        }
    }

    // --- Liquidation helper functions ---

    function _addLiquidationValuesToTotals(
        LiquidationTotals memory oldTotals,
        LiquidationValues memory singleLiquidation
    ) internal pure returns (LiquidationTotals memory newTotals) {
        // Tally all the values with their respective running totals
        newTotals.totalDebtInSequence =
            oldTotals.totalDebtInSequence +
            singleLiquidation.entireCdpDebt;
        newTotals.totalDebtToBurn = oldTotals.totalDebtToBurn + singleLiquidation.debtToBurn;
        newTotals.totalCollToSendToLiquidator =
            oldTotals.totalCollToSendToLiquidator +
            singleLiquidation.totalCollToSendToLiquidator;
        newTotals.totalDebtToRedistribute =
            oldTotals.totalDebtToRedistribute +
            singleLiquidation.debtToRedistribute;
        newTotals.totalCollSurplus = oldTotals.totalCollSurplus + singleLiquidation.collSurplus;
        newTotals.totalCollReward =
            oldTotals.totalCollReward +
            singleLiquidation.liquidatorCollSharesReward;

        return newTotals;
    }

    function _redistributeDebt(uint256 _debt) internal {
        if (_debt == 0) {
            return;
        }

        /*
         * Add distributed debt rewards-per-unit-staked to the running totals. Division uses a "feedback"
         * error correction, to keep the cumulative error low in the running totals systemDebtRedistributionIndex:
         *
         * 1) Form numerators which compensate for the floor division errors that occurred the last time this
         * function was called.
         * 2) Calculate "per-unit-staked" ratios.
         * 3) Multiply each ratio back by its denominator, to reveal the current floor division error.
         * 4) Store these errors for use in the next correction when this function is called.
         * 5) Note: static analysis tools complain about this "division before multiplication", however, it is intended.
         */
        uint256 EBTCDebtNumerator = (_debt * DECIMAL_PRECISION) + lastEBTCDebtErrorRedistribution;

        // Get the per-unit-staked terms
        uint256 _totalStakes = totalStakes;
        uint256 EBTCDebtRewardPerUnitStaked = EBTCDebtNumerator / _totalStakes;

        lastEBTCDebtErrorRedistribution =
            EBTCDebtNumerator -
            (EBTCDebtRewardPerUnitStaked * _totalStakes);

        // Add per-unit-staked terms to the running totals
        systemDebtRedistributionIndex = systemDebtRedistributionIndex + EBTCDebtRewardPerUnitStaked;

        emit SystemDebtRedistributionIndexUpdated(systemDebtRedistributionIndex);
    }

    // --- 'require' wrapper functions ---

    function _requirePartialLiqDebtSize(
        uint256 _partialDebt,
        uint256 _entireDebt,
        uint256 _price
    ) internal view {
        require(
            (_partialDebt + _convertDebtDenominationToBtc(MIN_NET_STETH_BALANCE, _price)) <=
                _entireDebt,
            "LiquidationLibrary: Partial debt liquidated must be less than total debt"
        );
    }

    function _requirePartialLiqCollSize(uint256 _entireColl) internal pure {
        require(
            _entireColl >= MIN_NET_STETH_BALANCE,
            "LiquidationLibrary: Coll remaining in partially liquidated CDP must be >= minimum"
        );
    }
}
