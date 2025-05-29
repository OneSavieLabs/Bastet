// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.22;

// External
import {RebaseLibrary, Rebase} from "@boringcrypto/boring-solidity/contracts/libraries/BoringRebase.sol";
import {BoringERC20} from "@boringcrypto/boring-solidity/contracts/libraries/BoringERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@boringcrypto/boring-solidity/contracts/ERC20.sol";

// Tapioca
import {IMarketLiquidatorReceiver} from "tapioca-periph/interfaces/bar/IMarketLiquidatorReceiver.sol";
import {ICluster} from "tapioca-periph/interfaces/periph/ICluster.sol";
import {IUsdo} from "tapioca-periph/interfaces/oft/IUsdo.sol";
import {SafeApprove} from "../../libraries/SafeApprove.sol";
import {BBCommon} from "./BBCommon.sol";

// solhint-disable max-line-length

/*

████████╗ █████╗ ██████╗ ██╗ ██████╗  ██████╗ █████╗ 
╚══██╔══╝██╔══██╗██╔══██╗██║██╔═══██╗██╔════╝██╔══██╗
   ██║   ███████║██████╔╝██║██║   ██║██║     ███████║
   ██║   ██╔══██║██╔═══╝ ██║██║   ██║██║     ██╔══██║
   ██║   ██║  ██║██║     ██║╚██████╔╝╚██████╗██║  ██║
   ╚═╝   ╚═╝  ╚═╝╚═╝     ╚═╝ ╚═════╝  ╚═════╝╚═╝  ╚═╝
   
*/

contract BBLiquidation is BBCommon {
    using RebaseLibrary for Rebase;
    using BoringERC20 for IERC20;
    using SafeCast for uint256;
    using SafeApprove for address;

    // ************** //
    // *** ERRORS *** //
    // ************** //
    error NothingToLiquidate();
    error LengthMismatch();
    error ForbiddenAction();
    error OnCollateralReceiverFailed();
    error BadDebt();
    error NotEnoughCollateral();
    error Solvent();
    error AmountNotValid();
    error InsufficientLiquidationBonus();
    error NotAuthorized();

    // *********************** //
    // *** OWNER FUNCTIONS *** //
    // *********************** //

    function liquidateBadDebt(
        address user,
        address from,
        address receiver,
        IMarketLiquidatorReceiver liquidatorReceiver,
        bytes calldata liquidatorReceiverData,
        bool swapCollateral
    ) external onlyOwner {
        _updateOracleRateForLiquidations();

        //check from whitelist status
        {
            bool isWhitelisted = ICluster(penrose.cluster()).isWhitelisted(0, from);
            if (!isWhitelisted) revert NotAuthorized();
        }

        // accrue before liquidation
        _accrue();
        penrose.reAccrueBigBangMarkets();

        // compute borrow amount with bonus
        uint256 elasticPart = totalBorrow.toElastic(userBorrowPart[user], false);
        uint256 borrowAmountWithBonus = elasticPart + (elasticPart * liquidationMultiplier) / FEE_PRECISION;
        uint256 requiredCollateral =
            yieldBox.toShare(collateralId, (borrowAmountWithBonus * exchangeRate) / EXCHANGE_RATE_PRECISION, false);

        uint256 collateralShare = userCollateralShare[user];
        if (requiredCollateral < collateralShare) revert ForbiddenAction();

        // update totalBorrow
        uint256 borrowAmount = totalBorrow.toElastic(userBorrowPart[user], true);
        totalBorrow.elastic -= borrowAmount.toUint128();
        totalBorrow.base -= userBorrowPart[user].toUint128();

        // update totalCollateralShare
        totalCollateralShare -= collateralShare;

        // set user share & part to 0
        userCollateralShare[user] = 0;
        userBorrowPart[user] = 0;

        // burn debt amount from `from`
        IUsdo(address(asset)).burn(from, borrowAmount);

        // swap collateral with asset and send it to `owner`
        if (swapCollateral) {
            (, uint256 returnedAmount) =
                _swapCollateralWithAsset(collateralShare, liquidatorReceiver, liquidatorReceiverData);
            asset.safeTransfer(receiver, returnedAmount);
        } else {
            uint256 collateralAmount = yieldBox.toAmount(collateralId, collateralShare, false);
            yieldBox.withdraw(collateralId, address(this), receiver, collateralAmount, 0);
        }
    }

    // ************************ //
    // *** PUBLIC FUNCTIONS *** //
    // ************************ //

    /// @notice Entry point for liquidations.
    /// @param users An array of user addresses.
    /// @param maxBorrowParts A one-to-one mapping to `users`, contains maximum (partial) borrow amounts (to liquidate) of the respective user
    /// @param minLiquidationBonuses minimum liquidation bonus acceptable
    /// @param liquidatorReceivers IMarketLiquidatorReceiver array
    /// @param liquidatorReceiverDatas IMarketLiquidatorReceiver datas
    function liquidate(
        address[] calldata users,
        uint256[] calldata maxBorrowParts,
        uint256[] calldata minLiquidationBonuses,
        IMarketLiquidatorReceiver[] calldata liquidatorReceivers,
        bytes[] calldata liquidatorReceiverDatas
    ) external optionNotPaused(PauseType.Liquidation) nonReentrant {
        if (users.length == 0) revert NothingToLiquidate();
        if (users.length != maxBorrowParts.length) revert LengthMismatch();
        if (users.length != liquidatorReceivers.length) revert LengthMismatch();
        if (liquidatorReceiverDatas.length != liquidatorReceivers.length) {
            revert LengthMismatch();
        }

        _updateOracleRateForLiquidations();

        _accrue();
        penrose.reAccrueBigBangMarkets();

        _closedLiquidation(
            users, maxBorrowParts, minLiquidationBonuses, liquidatorReceivers, liquidatorReceiverDatas, exchangeRate
        );
    }

    // ************************* //
    // *** PRIVATE FUNCTIONS *** //
    // ************************* //
    function _swapCollateralWithAsset(
        uint256 _collateralShare,
        IMarketLiquidatorReceiver _liquidatorReceiver,
        bytes memory _liquidatorReceiverData
    ) private returns (uint256 returnedShare, uint256 returnedAmount) {
        uint256 collateralAmount = yieldBox.toAmount(collateralId, _collateralShare, false);
        yieldBox.withdraw(collateralId, address(this), address(_liquidatorReceiver), collateralAmount, 0);

        uint256 assetBalanceBefore = asset.balanceOf(address(this));
        //msg.sender should be validated against `initiator` on IMarketLiquidatorReceiver
        _liquidatorReceiver.onCollateralReceiver(
            msg.sender, address(collateral), address(asset), collateralAmount, _liquidatorReceiverData
        );
        uint256 assetBalanceAfter = asset.balanceOf(address(this));

        returnedAmount = assetBalanceAfter - assetBalanceBefore;
        if (returnedAmount == 0) revert OnCollateralReceiverFailed();
        returnedShare = yieldBox.toShare(assetId, returnedAmount, false);
    }

    function _updateBorrowAndCollateralShare(
        address user,
        uint256 maxBorrowPart,
        uint256 minLiquidationBonus, // min liquidation bonus to accept (default 0)
        uint256 _exchangeRate
    ) private returns (uint256 borrowAmount, uint256 borrowPart, uint256 collateralShare) {
        if (_exchangeRate == 0) revert ExchangeRateNotValid();

        // get collateral amount in asset's value
        uint256 collateralPartInAsset = (
            yieldBox.toAmount(collateralId, userCollateralShare[user], false) * EXCHANGE_RATE_PRECISION
        ) / _exchangeRate;

        // compute closing factor (liquidatable amount)
        uint256 borrowPartWithBonus =
            computeClosingFactor(userBorrowPart[user], collateralPartInAsset, FEE_PRECISION_DECIMALS);

        // limit liquidable amount before bonus to the current debt
        uint256 userTotalBorrowAmount = totalBorrow.toElastic(userBorrowPart[user], true);
        borrowPartWithBonus = borrowPartWithBonus > userTotalBorrowAmount ? userTotalBorrowAmount : borrowPartWithBonus;

        // check the amount to be repaid versus liquidator supplied limit
        borrowPartWithBonus = borrowPartWithBonus > maxBorrowPart ? maxBorrowPart : borrowPartWithBonus;
        borrowAmount = borrowPartWithBonus;

        // compute part units, preventing rounding dust when liquidation is full
        borrowPart = borrowAmount == userTotalBorrowAmount
            ? userBorrowPart[user]
            : totalBorrow.toBase(borrowPartWithBonus, false);
        if (borrowPart == 0) revert Solvent();

        if (liquidationBonusAmount > 0) {
            borrowPartWithBonus = borrowPartWithBonus + (borrowPartWithBonus * liquidationBonusAmount) / FEE_PRECISION;
        }

        if (collateralPartInAsset < borrowPartWithBonus) {
            if (collateralPartInAsset <= userTotalBorrowAmount) {
                revert BadDebt();
            }
            // If current debt is covered by collateral fully
            // then there is some liquidation bonus,
            // so liquidation can proceed if liquidator's minimum is met
            if (minLiquidationBonus > 0) {
                // `collateralPartInAsset > borrowAmount` as `borrowAmount <= userTotalBorrowAmount`
                uint256 effectiveBonus = ((collateralPartInAsset - borrowAmount) * FEE_PRECISION) / borrowAmount;
                if (effectiveBonus < minLiquidationBonus) {
                    revert InsufficientLiquidationBonus();
                }
                collateralShare = userCollateralShare[user];
            } else {
                revert InsufficientLiquidationBonus();
            }
        } else {
            collateralShare =
                yieldBox.toShare(collateralId, (borrowPartWithBonus * _exchangeRate) / EXCHANGE_RATE_PRECISION, false);
            if (collateralShare > userCollateralShare[user]) {
                revert NotEnoughCollateral();
            }
        }

        userBorrowPart[user] -= borrowPart;
        userCollateralShare[user] -= collateralShare;
    }

    function _extractLiquidationFees(uint256 returnedShare, uint256 borrowShare, uint256 callerReward)
        private
        returns (uint256 feeShare, uint256 callerShare)
    {
        uint256 extraShare = returnedShare > borrowShare ? returnedShare - borrowShare : 0;
        callerShare = (extraShare * callerReward) / FEE_PRECISION; //  y%  of profit goes to caller.
        feeShare = extraShare - callerShare; // rest of the profit goes to fee.

        //protocol fees should be kept in the contract as we do a yieldBox.depositAsset when we are extracting the fees using `refreshPenroseFees`
        if (callerShare > 0) {
            address(asset).safeApprove(address(yieldBox), type(uint256).max);
            yieldBox.depositAsset(assetId, address(this), msg.sender, 0, callerShare);
        }
        address(asset).safeApprove(address(yieldBox), 0);
    }

    function _liquidateUser(
        address user,
        uint256 maxBorrowPart,
        IMarketLiquidatorReceiver _liquidatorReceiver,
        bytes calldata _liquidatorReceiverData,
        uint256 _exchangeRate,
        uint256 minLiquidationBonus
    ) private {
        uint256 callerReward = _getCallerReward(user, _exchangeRate);

        (uint256 borrowAmount,, uint256 collateralShare) =
            _updateBorrowAndCollateralShare(user, maxBorrowPart, minLiquidationBonus, _exchangeRate);
        totalCollateralShare = totalCollateralShare > collateralShare ? totalCollateralShare - collateralShare : 0;

        uint256 borrowShare = yieldBox.toShare(assetId, borrowAmount, true);

        (uint256 returnedShare,) =
            _swapCollateralWithAsset(collateralShare, _liquidatorReceiver, _liquidatorReceiverData);
        if (returnedShare < borrowShare) revert AmountNotValid();

        (uint256 feeShare, uint256 callerShare) = _extractLiquidationFees(returnedShare, borrowShare, callerReward);

        IUsdo(address(asset)).burn(address(this), borrowAmount);

        address[] memory _users = new address[](1);
        _users[0] = user;
        emit Liquidated(msg.sender, _users, callerShare, feeShare, borrowAmount, collateralShare);
    }

    struct __ClosedLiquidationCalldata {
        address user;
        uint256 maxBorrowPart;
        uint256 minLiquidationBonus;
        IMarketLiquidatorReceiver liquidatorReceiver;
    }
    /// @notice Handles the liquidation of users' balances, once the users' amount of collateral is too low.
    /// @dev Closed liquidations Only, 90% of extra shares goes to caller and 10% to protocol

    function _closedLiquidation(
        address[] calldata users,
        uint256[] calldata maxBorrowParts,
        uint256[] calldata minLiquidationBonuses,
        IMarketLiquidatorReceiver[] calldata liquidatorReceivers,
        bytes[] calldata liquidatorReceiverDatas,
        uint256 _exchangeRate
    ) private {
        uint256 liquidatedCount = 0;
        uint256 arrLength = users.length;

        __ClosedLiquidationCalldata memory calldata_; // Stack too deep fix

        for (uint256 i; i < arrLength;) {
            calldata_.user = users[i];
            calldata_.maxBorrowPart = maxBorrowParts[i];
            calldata_.minLiquidationBonus = minLiquidationBonuses[i];
            calldata_.liquidatorReceiver = liquidatorReceivers[i];

            if (!_isSolvent(calldata_.user, _exchangeRate, true)) {
                liquidatedCount++;
                _liquidateUser(
                    calldata_.user,
                    calldata_.maxBorrowPart,
                    calldata_.liquidatorReceiver,
                    liquidatorReceiverDatas[i],
                    _exchangeRate,
                    calldata_.minLiquidationBonus
                );
            }
            unchecked {
                ++i;
            }
        }

        require(liquidatedCount != 0, "BB: no users found");
    }
}
